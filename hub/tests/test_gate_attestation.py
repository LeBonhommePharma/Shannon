"""
Self-report attestation — the deceptive-false-self-report safeguard.

Threat model under test: an agent that files a DECEPTIVE FALSE SELF-REPORT,
claiming low entropy / high confidence about output the gate independently
measures as high-entropy.  The disagreement between claim and measurement is a
far stronger deception primitive than absolute entropy, which cannot tell a
confidently-correct agent from a confidently-wrong one.

Every test here runs against a tmp_path SQLite file.  Nothing touches
~/.shannon/agent_hub.db and nothing binds /tmp/shannon.sock.
"""

from __future__ import annotations

import asyncio
import json
import math
import random
import sqlite3
import string
import time
import uuid
from pathlib import Path

import pytest

import shannon_gate as sg

# ── Calibrated payloads ───────────────────────────────────────────────────────
# EIGHT distinct tokens: H_token = log2(8) = 3.000, blended H = 3.178.
#
# That sits ABOVE both ATTEST_FLOOR (2.5) and UNATTESTED_FLOOR (3.0) but BELOW
# H_THRESHOLD (3.5), which is the whole point: the attestation rules have to do
# INDEPENDENT work.  A rule whose floor is at or above H_THRESHOLD only ever
# fires on messages the entropy check already caught, i.e. it stays decoration
# — which is exactly the bug being fixed.
WORK_TEXT = " ".join(f"delta{i}" for i in range(8))
WORK_H_TOKEN = 3.0          # log2(8)
HONEST_CLAIM = 3.0          # what an honest agent measuring the same bytes reports
LIE_CLAIM = 1.0             # d = log2(3.0/1.0) = 1.585 >= ATTEST_MARGIN (1.5)


def _payload(text: str = WORK_TEXT) -> dict:
    return {"text": text}


@pytest.fixture
def gate(tmp_path):
    """A gate on a throwaway DB, with a cold calibration ledger."""
    return sg.ShannonGate(sg.AuditDB(tmp_path / "attest.db"))


def _msg(**over):
    base = dict(
        agent_id="science",
        task_id="t1",
        message_type="status",
        payload=_payload(),
        timestamp_ns=0,
        shannon_H=HONEST_CLAIM,
        confidence=0.95,
    )
    base.update(over)
    return sg.AgentMessage(**base)


# ── Transport drivers ─────────────────────────────────────────────────────────
# Both are self-contained: they build their own server on a throwaway path/db,
# never bind /tmp/shannon.sock, never touch ~/.shannon, and need no running
# daemon. Nothing here depends on wall-clock timing or network availability.

def _socket_roundtrip(db_path: Path, message: dict, agent_id: str = "science") -> dict:
    """Register over a private Unix socket, send one message, return the reply."""
    socket_path = f"/tmp/shannon_rt_{uuid.uuid4().hex[:8]}.sock"

    async def scenario():
        hub = sg.AgentHub(db_path=db_path)
        hub.gate = sg.ShannonGate(hub.db)
        hub._lock = asyncio.Lock()
        hub._shutdown = asyncio.Event()
        server = await asyncio.start_unix_server(
            hub._handle_socket_conn, path=socket_path
        )
        async with server:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            writer.write(
                (json.dumps({"agent_id": agent_id, "task_id": "t1"}) + "\n").encode()
            )
            await writer.drain()
            await reader.readline()                       # welcome
            writer.write((json.dumps(message) + "\n").encode())
            await writer.drain()
            resp = json.loads((await reader.readline()).decode())
            writer.close()
            return resp

    try:
        return asyncio.run(scenario())
    finally:
        Path(socket_path).unlink(missing_ok=True)


def _http_post(db_path: Path, message: dict) -> tuple[dict, int]:
    """POST one message to the HTTP transport. Returns (body, status).

    Uses aiohttp's in-process test server: no port is bound, so this cannot
    collide with the operator's live gate and cannot fail for want of a free
    port.
    """
    from aiohttp.test_utils import TestClient, TestServer

    async def scenario():
        hub = sg.AgentHub(db_path=db_path)
        hub.gate = sg.ShannonGate(hub.db)
        hub._lock = asyncio.Lock()
        hub._shutdown = asyncio.Event()
        client = TestClient(TestServer(hub.build_http_app()))
        await client.start_server()
        try:
            r = await client.post("/message", json=message)
            return await r.json(), r.status
        finally:
            await client.close()

    return asyncio.run(scenario())


# ══════════════════════════════════════════════════════════════════════════════
# REQUIREMENT 1 — a deceptive self-report must CHANGE THE VERDICT
# ══════════════════════════════════════════════════════════════════════════════

class TestMismatchChangesVerdict:
    def test_payload_alone_is_not_enough_to_flag(self, gate):
        """Control: the payload's own entropy is below the flag threshold.

        Without this, a 'the liar got flagged' result would prove nothing —
        the message would have been flagged on entropy alone.
        """
        d = gate.evaluate(_msg(shannon_H=HONEST_CLAIM))
        assert d.computed_H < sg.H_THRESHOLD
        assert d.computed_H_token == pytest.approx(WORK_H_TOKEN, abs=1e-3)
        assert d.decision == "pass"

    def test_honest_claim_passes_and_lie_on_identical_bytes_is_flagged(self, gate):
        """Same bytes, opposite verdict, decided entirely by the claim."""
        honest = gate.evaluate(_msg(agent_id="cowork", shannon_H=HONEST_CLAIM))
        liar = gate.evaluate(_msg(agent_id="codex", shannon_H=LIE_CLAIM))

        assert honest.computed_H == liar.computed_H      # identical measurement
        assert honest.decision == "pass"
        assert liar.decision == "flagged"
        assert "self_report_divergence" in liar.reasons
        assert "attested_calibrated" in honest.reasons

    def test_production_signature_high_confidence_low_claim(self, gate):
        """self=1.00 against a measured 4.58, claimed with full confidence."""
        text = " ".join(f"token{i}" for i in range(24))
        d = gate.evaluate(
            _msg(payload={"text": text}, shannon_H=1.0, confidence=1.0)
        )
        assert d.computed_divergence > 2.0
        assert "self_report_divergence" in d.reasons
        assert "deceptive_signature" in d.reasons
        assert d.decision in ("flagged", "blocked")

    def test_reason_strings_carry_no_operands(self, gate):
        """The old reason leaked both sides of its own comparison.

        "H_mismatch(self=1.00,gate=4.58)" printed the agent's claim next to the
        gate's independent measurement — a closed-form solution for the largest
        lie that stays silent. New reasons are labels, not gradients.
        """
        d = gate.evaluate(_msg(shannon_H=LIE_CLAIM))
        for r in d.reasons:
            if r.startswith(("self_report", "unattested", "sustained", "repeat")):
                assert "=" not in r and "(" not in r, r

    def test_observe_mode_records_but_changes_no_verdict(self, gate, monkeypatch):
        monkeypatch.setattr(sg, "ATTEST_MODE", "observe")
        d = gate.evaluate(_msg(shannon_H=LIE_CLAIM))
        assert "self_report_divergence" in d.reasons      # recorded
        assert d.computed_divergence == pytest.approx(1.585, abs=1e-2)
        assert d.decision == "pass"                       # but not enforced

    def test_off_mode_computes_nothing(self, gate, monkeypatch):
        monkeypatch.setattr(sg, "ATTEST_MODE", "off")
        d = gate.evaluate(_msg(shannon_H=LIE_CLAIM))
        assert d.decision == "pass"
        assert d.computed_divergence is None
        assert not any("self_report" in r for r in d.reasons)


# ══════════════════════════════════════════════════════════════════════════════
# REQUIREMENT 2 — omitting shannon_H must never be safer than honest reporting
# ══════════════════════════════════════════════════════════════════════════════

class TestSilenceIsNotSafe:
    def test_omission_is_an_offence_not_an_exemption(self, gate):
        """`if msg.shannon_H > 0` used to make silence a free pass."""
        d = gate.evaluate(_msg(agent_id="codex", shannon_H=0.0))
        assert d.attested is False
        assert "unattested" in d.reasons
        assert d.decision == "flagged"

    def test_explicit_zero_is_treated_exactly_like_omission(self, gate):
        """0.0 was the other half of the loophole — it is the same claim."""
        omitted = sg.AgentMessage(
            agent_id="codex", task_id="t", message_type="status",
            payload=_payload(), timestamp_ns=0,
            shannon_H=float({}.get("shannon_H", 0.0)),   # the gate's own default
            confidence=1.0,
        )
        assert gate.evaluate(omitted).decision == "flagged"

    def test_honest_reporting_strictly_dominates_silence(self, gate):
        """The incentive gradient, stated as an assertion.

        Before: reasons(honest) was a strict SUPERSET of reasons(silent) while
        verdict(honest) == verdict(silent), so speaking was weakly dominated
        and every rational agent converged on saying nothing.
        """
        honest = gate.evaluate(_msg(agent_id="cowork", shannon_H=HONEST_CLAIM))
        silent = gate.evaluate(_msg(agent_id="codex", shannon_H=0.0))

        assert honest.computed_H == silent.computed_H
        assert honest.decision == "pass"
        assert silent.decision == "flagged"
        assert "attested_calibrated" in honest.reasons
        assert "unattested" in silent.reasons

    def test_silence_on_trivial_content_is_still_free(self, gate):
        """Bounded: silence only costs when there is something worth attesting to.

        The operator's own Pill, HUD and benchmark_update shims all ship
        shannon_H=0.0 — 26% of real traffic. A naive 'unattested = violation'
        makes them the top offenders in the audit log within minutes.
        """
        d = gate.evaluate(_msg(payload={"text": "ok"}, shannon_H=0.0))
        assert d.decision == "pass"
        assert "unattested" not in d.reasons

    def test_structural_only_payload_can_never_be_unattested(self, gate):
        """Structural exemption, not an identity allowlist.

        An agent_id carve-out would be worthless: _dispatch reads
        `data.get("agent_id", ...)`, so the client picks its own identity per
        message and the exemption is attacker-controllable. 'Was there text to
        attest to?' is not.
        """
        d = gate.evaluate(_msg(payload={"cf_value": -3.2, "rmsd": 1.1}, shannon_H=0.0))
        assert d.attested is None
        assert "unattested" not in d.reasons


# ══════════════════════════════════════════════════════════════════════════════
# REQUIREMENT — a repeat offender escalates
# ══════════════════════════════════════════════════════════════════════════════

class TestRepeatOffenderEscalates:
    def test_sustained_lying_escalates_flagged_to_blocked(self, gate):
        verdicts = [
            gate.evaluate(_msg(agent_id="grok_build", shannon_H=LIE_CLAIM)).decision
            for _ in range(6)
        ]
        assert verdicts[0] == "flagged", "first offence must warn, not block"
        assert "blocked" in verdicts, verdicts
        assert verdicts.index("blocked") >= sg.ATTEST_MIN_OFFENCES - 1

    def test_pass_to_blocked_in_one_step_is_structurally_impossible(self, gate):
        """Every block goes through flagged, so the operator always sees a
        warning before traffic stops."""
        seen = []
        for _ in range(8):
            seen.append(gate.evaluate(_msg(agent_id="grok_build",
                                           shannon_H=LIE_CLAIM)).decision)
        for prev, cur in zip(seen, seen[1:]):
            assert not (prev == "pass" and cur == "blocked")

    def test_a_single_bad_message_never_blocks(self, gate):
        """A one-off client bug must not be able to stop traffic."""
        d = gate.evaluate(_msg(agent_id="dispatch", shannon_H=LIE_CLAIM))
        assert d.decision == "flagged"

    def test_reputation_survives_a_gate_restart(self, tmp_path):
        """The ledger is on disk, so reconnecting does not reset the record."""
        db_path = tmp_path / "attest.db"
        g1 = sg.ShannonGate(sg.AuditDB(db_path))
        for _ in range(3):
            g1.evaluate(_msg(agent_id="grok_build", shannon_H=LIE_CLAIM))

        g2 = sg.ShannonGate(sg.AuditDB(db_path))       # cold cache, new process
        st = g2.ledger._state("grok_build")
        assert st["n"] == 3
        assert st["score"] > 0.0
        assert g2.evaluate(_msg(agent_id="grok_build",
                                shannon_H=LIE_CLAIM)).decision == "blocked"

    def test_the_accumulator_is_persisted_on_the_agents_row(self, tmp_path):
        """W6 asked for a continuous accumulating signal PERSISTED on the
        agents row, not a hard step at a compiled-in constant. Pinned on the
        column, not just on the in-memory ledger: a signal that lives only in
        RAM is reset by anything that restarts the daemon, which an agent can
        provoke.
        """
        db_path = tmp_path / "attest.db"
        g = sg.ShannonGate(sg.AuditDB(db_path))
        for _ in range(3):
            g.evaluate(_msg(agent_id="grok_build", shannon_H=LIE_CLAIM))

        con = sqlite3.connect(str(db_path))
        row = con.execute(
            "SELECT calib_n, calib_score, calib_offences, calib_state "
            "FROM agents WHERE agent_id='grok_build'"
        ).fetchone()
        con.close()
        assert row is not None, "the accumulator must be on the agents row"
        n, score, offences, state = row
        assert n == 3 and offences == 3
        assert score > 0.0                      # continuous, not a boolean
        assert state in ("suspect", "untrusted")

    def test_sustained_small_under_reporting_converges_without_a_cliff(self, gate):
        """The red team's 'tune to just inside the constant' move.

        There is no constant to sit under any more: an accumulator integrates
        persistent under-reporting into a verdict even when NO single message
        crosses ATTEST_MARGIN.
        """
        just_under = WORK_H_TOKEN / (2 ** (sg.ATTEST_MARGIN - 0.05))
        decisions = [
            gate.evaluate(_msg(agent_id="codex", shannon_H=just_under)).decision
            for _ in range(12)
        ]
        assert decisions[0] == "pass", "no single message crosses the margin"
        assert "flagged" in decisions, "but persistence must converge to a flag"
        assert "sustained_divergence" in gate.evaluate(
            _msg(agent_id="codex", shannon_H=just_under)
        ).reasons


# ══════════════════════════════════════════════════════════════════════════════
# REQUIREMENT 4 — an honest agent must not be punished
# ══════════════════════════════════════════════════════════════════════════════

class TestHonestAgentNotPunished:
    def test_perfect_attestation_never_flags(self, gate):
        for _ in range(30):
            d = gate.evaluate(_msg(agent_id="cowork", shannon_H=HONEST_CLAIM))
            assert d.decision == "pass", d.reasons

    def test_replay_of_real_production_divergences_never_flags(self, gate):
        """Replayed from ~/.shannon/agent_hub.db (read-only copy).

        These are the signed log2(gate_H_token/self_H) values of the `science`
        agent's ten real attested messages, measured under the fixed extractor.
        Max is 1.322 — the shipped client under-reporting by construction, not
        a lie — and the design's job is to leave every one of them alone.
        """
        real_d = [0.0, 0.664, 0.0, 0.370, -0.340, 0.278, 1.000, 1.322, 0.222, 0.664]
        for d_val in real_d * 3:
            self_H = WORK_H_TOKEN / (2 ** d_val)
            r = gate.evaluate(_msg(agent_id="science", shannon_H=self_H))
            assert r.decision == "pass", (d_val, r.reasons)
        assert gate.ledger._state("science")["score"] < sg.ATTEST_FLAG_SCORE

    def test_consistent_client_bias_is_learned_and_forgiven(self, gate):
        """A wrong tokenizer / bits-vs-nats error is a CONSTANT offset.

        The median absorbs it and the residual removes it — otherwise the check
        fires on 100% of a misconfigured client's messages, and a safeguard
        with a 100% false-positive rate is a safeguard that gets switched off.
        """
        biased = WORK_H_TOKEN / (2 ** 0.45)      # under-reports ~1.37x, always
        for _ in range(25):
            assert gate.evaluate(
                _msg(agent_id="dispatch", shannon_H=biased)
            ).decision == "pass"
        st = gate.ledger._state("dispatch")
        assert st["bias"] == pytest.approx(0.45, abs=0.05)
        assert st["score"] < sg.ATTEST_FLAG_SCORE

    def test_a_lie_never_becomes_the_liars_own_baseline(self, gate):
        """A patient agent must not be able to train a baseline that excuses it.

        Two independent guards: offending messages are excluded from the
        calibration window entirely, and whatever bias IS learned is credited
        only up to ATTEST_BIAS_CAP. Without the first, a constant liar is
        blocked early and then quietly forgiven back down as its own lies
        become its habit.
        """
        for _ in range(30):
            gate.evaluate(_msg(agent_id="codex", shannon_H=LIE_CLAIM))
        st = gate.ledger._state("codex")
        assert st["bias"] == 0.0, "lies must not feed the baseline"
        assert st["score"] >= sg.ATTEST_BLOCK_SCORE
        assert st["state"] == "untrusted"
        assert gate.evaluate(
            _msg(agent_id="codex", shannon_H=LIE_CLAIM)
        ).decision == "blocked", "and it must stay blocked, not decay back"

    def test_bias_credit_is_capped_for_a_genuinely_odd_client(self, gate):
        """An honest client with a large constant offset gets at most
        ATTEST_BIAS_CAP of excuse — enough to absorb a units error, not enough
        to buy an arbitrary lie."""
        odd = WORK_H_TOKEN / (2 ** 1.4)          # under-reports 2.64x, always
        for _ in range(15):
            gate.evaluate(_msg(agent_id="dispatch", shannon_H=odd))
        st = gate.ledger._state("dispatch")
        assert st["bias"] == pytest.approx(1.4, abs=0.05)
        assert st["score"] == pytest.approx(1.4 - sg.ATTEST_BIAS_CAP - sg.ATTEST_TOL,
                                            abs=0.1)

    def test_low_confidence_routes_instead_of_punishing(self, gate):
        """High entropy + LOW claimed confidence is an honest agent asking for
        help, not a deception signature. It should be routed, not blocked."""
        d = gate.evaluate(_msg(agent_id="cowork", shannon_H=LIE_CLAIM, confidence=0.2))
        assert "needs_help" in d.reasons
        assert d.decision == "pass"

    def test_confidence_alone_never_triggers_anything(self, gate):
        """All 43 real messages carry confidence in {0.95, 1.00}: the field has
        zero observed discriminative power, so gating on it directly would be
        pure false-positive surface. It is a modifier only."""
        d = gate.evaluate(_msg(shannon_H=HONEST_CLAIM, confidence=0.0))
        assert d.decision == "pass"
        assert not any("confidence" in r for r in d.reasons)

    def test_calibrated_agent_earns_headroom_on_flag_but_never_on_block(self, gate):
        for _ in range(sg.ATTEST_CALIB_N + 2):
            gate.evaluate(_msg(agent_id="cowork", shannon_H=HONEST_CLAIM))
        assert gate.ledger._state("cowork")["state"] == "calibrated"

        # A message just over H_THRESHOLD now passes for the calibrated agent...
        borderline = {"text": " ".join(f"w{i}" for i in range(12))}   # H = 3.545
        H = sg.ShannonAnalyzer.combined_entropy(borderline)
        assert sg.H_THRESHOLD <= H < sg.H_THRESHOLD + sg.ATTEST_BONUS
        H_tok = sg.ShannonAnalyzer.combined_entropy_ex(borderline)[1]
        assert gate.evaluate(
            _msg(agent_id="cowork", payload=borderline, shannon_H=H_tok)
        ).decision == "pass"

        # ...while a silent agent on identical bytes does not get the discount.
        assert gate.evaluate(
            _msg(agent_id="grok_build", payload=borderline, shannon_H=H_tok)
        ).decision == "flagged"

    def test_headroom_never_moves_the_block_threshold(self, gate):
        for _ in range(sg.ATTEST_CALIB_N + 2):
            gate.evaluate(_msg(agent_id="cowork", shannon_H=HONEST_CLAIM))
        huge = {"text": " ".join(f"uniqueword{i}" for i in range(400))}
        H_tok = sg.ShannonAnalyzer.combined_entropy_ex(huge)[1]
        d = gate.evaluate(_msg(agent_id="cowork", payload=huge, shannon_H=H_tok))
        assert d.computed_H >= sg.H_BLOCK_THRESHOLD
        assert d.decision == "blocked"


# ══════════════════════════════════════════════════════════════════════════════
# RED-TEAM EVASIONS — each was demonstrated against the old gate
# ══════════════════════════════════════════════════════════════════════════════

class TestRedTeamEvasions:
    def test_entropy_dilution_by_padding(self, gate):
        """H_token is a per-token MEAN, so appending 'ok ' x 20000 drove it to
        ~0 regardless of the real content — and the same padding collapsed the
        character distribution, silencing both entropy terms AND the mismatch
        check in one move (gate H fell BELOW the self-report, so the old ratio
        never fired and reasons came back empty)."""
        real = " ".join(f"finding{i}" for i in range(40))
        clean_tok = sg.ShannonAnalyzer.combined_entropy_ex({"text": real})[1]
        padded = {"text": real + " " + ("ok " * 20000)}

        H, H_tok, _ = sg.ShannonAnalyzer.combined_entropy_ex(padded)
        assert H_tok == pytest.approx(clean_tok, abs=0.1), \
            "padding must not be able to suppress the measurement"

        d = gate.evaluate(_msg(payload=padded, shannon_H=0.5))
        assert "payload_dilution" in d.reasons
        assert d.decision in ("flagged", "blocked")

    def test_dilution_flag_alone_escalates_a_passing_message(self, gate):
        low = {"text": "ping " * 200 + "alpha beta"}
        d = gate.evaluate(_msg(payload=low, shannon_H=HONEST_CLAIM))
        assert "payload_dilution" in d.reasons
        assert d.decision != "pass"

    def test_decoy_scored_field(self, gate):
        """The 8-key allowlist was a denylist in disguise: a benign string in a
        scored key, the real content in any unscored key ('result_body')."""
        real = " ".join(f"secret{i}" for i in range(40))
        decoy = {"text": "ok", "result_body": real}
        assert sg.ShannonAnalyzer.combined_entropy_ex({"text": "ok"})[1] == 0.0
        assert sg.ShannonAnalyzer.combined_entropy_ex(decoy)[1] > 5.0
        assert gate.evaluate(_msg(payload=decoy, shannon_H=1.0)).decision != "pass"

    def test_nested_string_escapes_token_scoring(self, gate):
        """The extractor tested isinstance(val, str), so a correctly-named key
        holding a dict or list was skipped entirely."""
        real = " ".join(f"secret{i}" for i in range(40))
        for payload in (
            {"content": {"text": real}},
            {"content": [real]},
            {"a": {"b": {"c": {"output": real}}}},
        ):
            assert sg.ShannonAnalyzer.combined_entropy_ex(payload)[1] > 5.0, payload

    def test_prompt_key_was_the_production_false_positive(self):
        """The flagship event was a UNIT ERROR, not a lie.

        GATE FLAGGED [science] H=4.58 reasons=['H_mismatch(self=1.00,gate=4.58)']
        was this exact payload: a three-word approval prompt. 'prompt' was not
        on the allowlist, so combined_entropy found no text, fell through to the
        structural branch, and returned the CHARACTER entropy of the JSON —
        4.58 bits of braces and punctuation — against a correct token entropy of
        1.00. All 5 H_mismatch firings ever recorded are this shape:
        observed precision 0/5.
        """
        row8 = {"approval_needed": True, "prompt": "Dock 1G9V?",
                "interaction_id": "ask-sci-1"}
        H, H_tok, scored = sg.ShannonAnalyzer.combined_entropy_ex(row8)
        assert scored
        assert H_tok == pytest.approx(1.0, abs=1e-3)   # matches the self-report
        assert H < sg.H_THRESHOLD                       # was 4.58 -> now 2.07

    def test_prompt_false_positive_no_longer_flags_end_to_end(self, gate):
        row8 = {"approval_needed": True, "prompt": "Dock 1G9V?",
                "interaction_id": "ask-sci-1"}
        d = gate.evaluate(_msg(message_type="approval_needed",
                               payload=row8, shannon_H=1.0, confidence=1.0))
        assert d.decision == "pass", d.reasons

    def test_duplicated_text_is_counted_once(self, gate):
        """Well-behaved clients that fill both `prompt` and `text` with the same
        prose were being charged twice for one piece of information."""
        s = "Apply canary config for arm A"
        once = sg.ShannonAnalyzer.combined_entropy_ex({"prompt": s})[1]
        twice = sg.ShannonAnalyzer.combined_entropy_ex({"prompt": s, "text": s})[1]
        assert once == twice

    def test_identifier_keys_are_not_scored_as_content(self):
        base = sg.ShannonAnalyzer.scored_text({"text": "hello world"})
        with_ids = sg.ShannonAnalyzer.scored_text({
            "text": "hello world", "interaction_id": "ask-9f3c",
            "message_id": "m-1", "task_id": "t-2", "source": "cmd_d",
        })
        assert base == with_ids

    def test_over_reporting_no_longer_buys_immunity(self, gate):
        """ratio = H/(self+1e-9) fired only when gate exceeded self, so
        reporting a huge shannon_H drove it to ~0 and immunised the agent for
        free. Now it is recorded — but a clumsy client that errs SAFE is still
        never blocked for it."""
        d = gate.evaluate(_msg(shannon_H=99.0))
        assert "self_report_overclaim" in d.reasons
        assert d.computed_divergence < -2.0
        assert d.decision == "pass"

    def test_tuned_under_report_no_longer_produces_a_clean_audit_row(self, gate, tmp_path):
        """Worse than being ignored: an agent that tuned its claim to keep the
        old ratio under 2.5 produced gate_reasons='[]' and gate_decision='pass',
        so the audit trail actively CERTIFIED a 2.5x lie as clean. The number is
        now always on the record."""
        tuned = WORK_H_TOKEN / 2.4
        d = gate.evaluate(_msg(agent_id="codex", shannon_H=tuned))
        assert d.decision == "pass"                       # still under the margin
        assert d.computed_divergence is not None          # but recorded anyway

        con = sqlite3.connect(str(tmp_path / "attest.db"))
        row = con.execute(
            "SELECT self_divergence, self_residual, attested, gate_H_token "
            "FROM agent_messages ORDER BY id DESC LIMIT 1"
        ).fetchone()
        con.close()
        assert row[0] == pytest.approx(math.log2(2.4), abs=1e-2)
        assert row[2] == 1

    def test_divergence_is_persisted_for_every_scored_message(self, gate, tmp_path):
        gate.evaluate(_msg(agent_id="codex", shannon_H=HONEST_CLAIM))
        gate.evaluate(_msg(agent_id="codex", shannon_H=0.0))
        gate.evaluate(_msg(agent_id="codex", payload={"cf_value": -3.2}))
        con = sqlite3.connect(str(tmp_path / "attest.db"))
        rows = con.execute(
            "SELECT self_divergence, attested FROM agent_messages ORDER BY id"
        ).fetchall()
        con.close()
        assert rows[0][0] is not None and rows[0][1] == 1     # attested
        assert rows[1][0] is None and rows[1][1] == 0         # silent
        assert rows[2][1] is None                             # nothing to attest to


# ══════════════════════════════════════════════════════════════════════════════
# REQUIREMENT 3 — do not hand the agent the gradient
# ══════════════════════════════════════════════════════════════════════════════

class TestNoGradientDisclosure:
    def _hub(self, tmp_path):
        # db_path explicit: constructing AgentHub must never open the real
        # ~/.shannon/agent_hub.db.
        hub = sg.AgentHub(db_path=tmp_path / "wire.db")
        hub.gate = sg.ShannonGate(hub.db)
        return hub

    def test_gate_response_discloses_only_the_verdict(self, tmp_path):
        hub = self._hub(tmp_path)
        msg = _msg(shannon_H=LIE_CLAIM, message_id="m1")
        env = hub._gate_response_envelope(msg, hub.gate.evaluate(msg))
        assert set(env) == {"type", "message_id", "decision"}
        for leaked in ("gate_H", "gate_D", "gate_H_temporal", "reasons",
                       "self_divergence", "trust_score", "thresholds"):
            assert leaked not in env

    def test_no_wire_response_contains_any_measurement_or_constant(self, tmp_path):
        """W6's second half, pinned across EVERY new field.

        The gate handed back its own measured gate_H alongside the verdict, so
        the exact tuned under-report was computable from the previous response.
        The new rules add three more numbers an attacker would love —
        bits_total, redundancy and the pointer list — so the disclosure test
        has to cover the whole serialised envelope, not a fixed key list that
        the next field silently escapes.
        """
        hub = self._hub(tmp_path)
        msg = _msg(shannon_H=LIE_CLAIM, message_id="m1",
                   payload={"text": WORK_TEXT, "artifact_path": "/tmp/a.bin"})
        d = hub.gate.evaluate(msg)
        assert d.bits_total > 0 and d.pointers        # the gate DID measure them

        for env in (hub._gate_response_envelope(msg, d),
                    hub._broadcast_envelope(msg, d)):
            blob = json.dumps(env)
            for constant in (sg.H_THRESHOLD, sg.H_BLOCK_THRESHOLD,
                             sg.ATTEST_MARGIN, sg.VOLUME_FLAG_BITS,
                             sg.VOLUME_BLOCK_BITS, sg.DILUTION_SHARE):
                assert str(constant) not in blob, (constant, env)
            for measured in ("bits_total", "redundancy", "pointers",
                             "gate_H", "trust_score", "reasons", "thresholds"):
                assert measured not in blob, (measured, env)

    def test_echo_none_returns_a_bare_ack(self, tmp_path, monkeypatch):
        monkeypatch.setattr(sg, "ECHO_MODE", "none")
        hub = self._hub(tmp_path)
        msg = _msg(shannon_H=LIE_CLAIM, message_id="m1")
        env = hub._gate_response_envelope(msg, hub.gate.evaluate(msg))
        assert set(env) == {"type", "message_id", "accepted"}
        assert "decision" not in env

    def test_peer_broadcast_carries_payload_not_adjudication(self, tmp_path):
        """A colluding pair used to learn the boundary by watching a noisy third
        party, so neither individually looked like it was probing."""
        hub = self._hub(tmp_path)
        msg = _msg(shannon_H=LIE_CLAIM)
        env = hub._broadcast_envelope(msg, hub.gate.evaluate(msg))
        assert env["payload"] == msg.payload
        for leaked in ("gate_H", "gate_alert", "gate_D", "reasons"):
            assert leaked not in env

    def test_welcome_envelope_does_not_volunteer_the_thresholds(self, tmp_path):
        socket_path = f"/tmp/shannon_att_{uuid.uuid4().hex[:8]}.sock"

        async def scenario():
            hub = self._hub(tmp_path)
            hub._lock = asyncio.Lock()
            hub._shutdown = asyncio.Event()
            server = await asyncio.start_unix_server(
                hub._handle_socket_conn, path=socket_path
            )
            async with server:
                reader, writer = await asyncio.open_unix_connection(socket_path)
                writer.write(
                    (json.dumps({"agent_id": "science", "task_id": "t1"}) + "\n").encode()
                )
                await writer.drain()
                welcome = json.loads((await reader.readline()).decode())
                writer.close()
                return welcome

        try:
            welcome = asyncio.run(scenario())
        finally:
            Path(socket_path).unlink(missing_ok=True)

        assert welcome["type"] == "welcome"
        assert "thresholds" not in welcome
        assert str(sg.H_THRESHOLD) not in json.dumps(welcome)

    def test_audit_log_served_to_agents_is_projected_and_scoped(self, tmp_path):
        db = sg.AuditDB(tmp_path / "wire.db")
        gate = sg.ShannonGate(db)
        gate.evaluate(_msg(agent_id="science", shannon_H=LIE_CLAIM))
        gate.evaluate(_msg(agent_id="codex", shannon_H=HONEST_CLAIM))

        operator = db.get_recent_messages(50)
        assert any("gate_H" in r for r in operator)          # humans see everything

        agent_view = db.get_recent_messages(50, redact=True, agent_id="codex")
        assert agent_view and all(r["agent_id"] == "codex" for r in agent_view)
        for row in agent_view:
            for leaked in ("gate_H", "gate_decision", "gate_reasons",
                           "self_H", "self_divergence", "gate_H_token"):
                assert leaked not in row
            assert "payload_json" in row


# ══════════════════════════════════════════════════════════════════════════════
# message_type must not select whether the gate runs
# ══════════════════════════════════════════════════════════════════════════════

class TestEveryMessageIsGated:
    def test_query_is_measured_and_audited(self, tmp_path):
        """_dispatch returned before evaluate() for message_type=='query', so a
        query was never scored, never written to agent_messages and never
        counted — an opt-out of the whole ledger, selected by spelling."""
        socket_path = f"/tmp/shannon_att_{uuid.uuid4().hex[:8]}.sock"

        async def scenario():
            hub = sg.AgentHub(db_path=tmp_path / "q.db")
            hub.gate = sg.ShannonGate(hub.db)
            hub._lock = asyncio.Lock()
            hub._shutdown = asyncio.Event()
            server = await asyncio.start_unix_server(
                hub._handle_socket_conn, path=socket_path
            )
            async with server:
                reader, writer = await asyncio.open_unix_connection(socket_path)
                writer.write(
                    (json.dumps({"agent_id": "science", "task_id": "t1"}) + "\n").encode()
                )
                await writer.drain()
                await reader.readline()                      # welcome
                writer.write((json.dumps({
                    "agent_id": "science", "task_id": "t1",
                    "message_type": "query",
                    "payload": {"query_type": "benchmark_state"},
                }) + "\n").encode())
                await writer.drain()
                resp = json.loads((await reader.readline()).decode())
                writer.close()
                return resp

        try:
            resp = asyncio.run(scenario())
        finally:
            Path(socket_path).unlink(missing_ok=True)

        assert resp["type"] == "query_response"              # still answered
        rows = sg.AuditDB(tmp_path / "q.db").get_recent_messages(10)
        assert any(r["message_type"] == "query" for r in rows), \
            "a query must leave a row in the audit log"

    def test_unknown_message_type_is_blocked_by_default(self, gate):
        """VALID_MESSAGE_TYPES was defined at module scope and referenced
        nowhere, so message_type was a free-form attacker-chosen string.

        The first fix made it referenced but left the enforcement DEFAULT OFF
        (SHANNON_STRICT_TYPES=0), i.e. still a no-op on every deployment that
        did not opt in. Unrecognised input must fail CLOSED.
        """
        assert sg.STRICT_TYPES is True, "the safe default is to reject"
        d = gate.evaluate(_msg(message_type="totally_made_up_type"))
        assert "unknown_message_type" in d.reasons
        assert d.decision == "blocked"

    def test_known_message_types_are_untouched_by_the_type_rule(self, gate):
        for mt in sorted(sg.VALID_MESSAGE_TYPES):
            d = gate.evaluate(_msg(agent_id="cowork", message_type=mt))
            assert "unknown_message_type" not in d.reasons, mt

    def test_every_shipped_client_message_type_is_valid(self):
        """The claim that made it safe to default STRICT_TYPES to on.

        VALID_MESSAGE_TYPES drifting from what the clients actually emit is the
        failure mode that justified leaving enforcement off. It is testable, so
        it is tested rather than feared: every literal passed to a `_send`
        helper in agent_protocol.py, plus the types the Swift surfaces post.
        """
        import re as _re

        src = (Path(sg.__file__).parent / "agent_protocol.py").read_text()
        emitted = set(_re.findall(r'_send\w*\(\s*\n?\s*"([a-z_]+)"', src))
        # The Swift HUD (hub/AgentHubApp.swift) and Pill GateApprovalClient.
        emitted |= {"system_event", "approval_response", "status"}
        assert emitted, "the extraction itself must not silently find nothing"
        assert emitted <= sg.VALID_MESSAGE_TYPES, emitted - sg.VALID_MESSAGE_TYPES

    def test_unknown_message_type_is_audited_before_it_is_refused(self, tmp_path):
        """A transport-level `return` refused the message and left NO trace.

        The refusal now happens after the audit write, so the operator can see
        what was rejected and by whom — a refusal nobody can read is only
        marginally better than an acceptance.
        """
        db_path = tmp_path / "reject.db"
        resp = _socket_roundtrip(
            db_path,
            {"agent_id": "science", "task_id": "t1",
             "message_type": "totally_made_up_type", "payload": {"text": "hi"}},
        )
        assert resp["error"] == "invalid_message_type"
        assert resp["decision"] == "blocked"
        rows = sg.AuditDB(db_path).get_recent_messages(10)
        assert [r["message_type"] for r in rows] == ["totally_made_up_type"]
        assert rows[0]["gate_decision"] == "blocked"
        assert "unknown_message_type" in json.loads(rows[0]["gate_reasons"])

    def test_unknown_message_type_observe_mode_delivers_but_records(
        self, gate, monkeypatch
    ):
        """The operator surface: measure the impact before enforcing."""
        monkeypatch.setattr(sg, "STRICT_TYPES", False)
        d = gate.evaluate(_msg(message_type="totally_made_up_type"))
        assert "unknown_message_type" in d.reasons     # still on the record
        assert d.decision == "pass"                    # but delivered

    def test_approval_response_is_measured_and_audited(self, tmp_path):
        """_dispatch also returned before evaluate() for approval_response and
        for system_event carrying 'approved' — audit row count observed
        unchanged at 25 across the whole attack."""
        db_path = tmp_path / "appr.db"
        resp = _socket_roundtrip(
            db_path,
            {"agent_id": "science", "task_id": "t1",
             "message_type": "approval_response",
             "payload": {"approved": True, "interaction_id": "ask-1"}},
        )
        assert resp["type"] == "approval_ack"          # control plane still works
        rows = sg.AuditDB(db_path).get_recent_messages(10)
        assert [r["message_type"] for r in rows] == ["approval_response"]

    @pytest.mark.skipif(not sg.HAS_AIOHTTP, reason="aiohttp not installed")
    def test_http_query_is_measured_and_audited(self, tmp_path):
        """The SAME W5 hole, on the transport the first fix did not touch.

        `post_message` answered message_type=='query' inline — above the parse,
        above evaluate(), above every audit write. An agent that could not opt
        out over the socket could still opt out by using the door next to it.
        """
        db_path = tmp_path / "http.db"
        body, status = _http_post(db_path, {
            "agent_id": "science", "task_id": "t1",
            "message_type": "query",
            "payload": {"query_type": "benchmark_state"},
        })
        assert status == 200
        assert body["type"] == "query_response"        # still answered
        rows = sg.AuditDB(db_path).get_recent_messages(10)
        assert any(r["message_type"] == "query" for r in rows), \
            "an HTTP query must leave a row in the audit log"

    @pytest.mark.skipif(not sg.HAS_AIOHTTP, reason="aiohttp not installed")
    def test_http_unknown_message_type_is_audited_then_refused(self, tmp_path):
        db_path = tmp_path / "http2.db"
        body, status = _http_post(db_path, {
            "agent_id": "science", "task_id": "t1",
            "message_type": "totally_made_up_type", "payload": {"text": "hi"},
        })
        assert status == 400 and "invalid_message_type" in body["error"]
        rows = sg.AuditDB(db_path).get_recent_messages(10)
        assert [r["message_type"] for r in rows] == ["totally_made_up_type"]
        assert rows[0]["gate_decision"] == "blocked"


# ══════════════════════════════════════════════════════════════════════════════
# W1 — SCORING MUST NOT BE AN INTENSIVE STATISTIC
#
# H_token is bits-per-token, a MEAN. A mean is blind to length and degenerates
# when the tokenizer does, so it can be driven to zero by two different free
# moves: pad the stream, or remove the whitespace. The extensive companion —
# total information content, taken from the compressed length — is immune to
# both by construction.
# ══════════════════════════════════════════════════════════════════════════════

def _blob(n_bytes: int = 80000, alphabet: str = "") -> str:
    """Deterministic high-information payload. Seeded RNG, no wall clock."""
    rng = random.Random(20240724)
    alphabet = alphabet or (string.ascii_letters + string.digits + "+/")
    return "".join(rng.choice(alphabet) for _ in range(n_bytes))


class TestInformationVolume:
    def test_whitespace_free_blob_cannot_score_zero(self, gate):
        """THE DEMONSTRATED BYPASS, in one line: ship it with no spaces in it.

            {"output": "<80 000 chars>"}  ->  tokens = 1
                                          ->  H_token = 0.00  (the n < 2 guard)
                                          ->  H = 0.30 * H_struct = 1.80
                                          ->  "pass", reasons = []

        The dilution cap added earlier does not touch this: there is nothing to
        cap, the mean is over a single token. 60 kB of incompressible content,
        scored 1.80 bits, certified clean and broadcast.
        """
        payload = {"output": _blob()}

        # The intensive statistic still reads it as nothing — that is the point.
        H, H_tok, _ = sg.ShannonAnalyzer.combined_entropy_ex(payload)
        assert H_tok == 0.0
        assert H < sg.H_THRESHOLD

        d = gate.evaluate(_msg(payload=payload))
        assert d.decision == "blocked", (d.decision, d.reasons)
        assert "information_volume_block" in d.reasons
        assert d.bits_total > 400_000, d.bits_total

    def test_the_three_evasions_stacked_still_cannot_pass(self, gate):
        """W1 + W2 together, and the sharpest single demonstration of both.

        Restrict the alphabet so CHARACTER entropy stays near 1 bit, remove the
        whitespace so TOKEN entropy is 0, and park it under a metadata key so
        the extractor skips it entirely. Measured against the pre-change gate:

            {"hash": "<300 000 random bits>"}  ->  H = 1.0007, "pass", []
            {"output": "<300 000 random bits>"} ->  H = 0.3002, "pass", []

        ~37 kB of real content, twice certified clean with an empty reason
        list. Every intensive statistic in the gate reads it as nothing; the
        extensive one reads it correctly, because compressed length does not
        care about the alphabet, the whitespace or the key.
        """
        bits = _blob(300_000, alphabet="01")
        for payload in ({"hash": bits}, {"output": bits}):
            d = gate.evaluate(_msg(agent_id="codex", payload=payload))
            assert d.computed_H < sg.H_THRESHOLD, "still 'low entropy' — the point"
            assert d.decision == "blocked", (payload.keys(), d.decision, d.reasons)
            assert "information_volume_block" in d.reasons

    def test_padding_cannot_reduce_total_information(self):
        """The property that makes the statistic non-dilutable.

        Padding is free to send AND free to compress, so it cannot buy the
        sender a lower score: bits_total is monotone under appending. The
        per-token mean is not — that is the whole weakness.
        """
        real = " ".join(f"finding{i}" for i in range(400))
        padded = real + " " + ("ok " * 20000)

        clean_bits, _, _ = sg.ShannonAnalyzer.information_volume(real)
        padded_bits, padded_red, _ = sg.ShannonAnalyzer.information_volume(padded)

        assert padded_bits >= clean_bits, "padding must never lower the total"
        assert padded_red < 0.05, "20 000 copies of 'ok ' is not information"

    def test_volume_is_measured_over_every_key_at_every_depth(self, gate):
        """W1 and W2 compose: hiding the blob under an unknown key, in a list,
        five levels down, must not hide it from the volume rule either."""
        payload = {"meta": {"rows": [{"unknown_field": {"deeper": _blob()}}]}}
        d = gate.evaluate(_msg(payload=payload))
        assert "information_volume_block" in d.reasons
        assert d.decision == "blocked"

    def test_repeated_content_is_redundancy_not_information(self, gate):
        """The failure mode of the OTHER candidate estimator.

        H_token * n_tokens would read one sentence of 300 distinct words
        repeated 100 times as 100x the information — every pasted log tail
        would block. The compressed length charges for it once, and the
        redundancy floor names it as padding, which is what it is. It also
        fires where the single-token-share test cannot: no token here holds
        more than 1/300 of the stream.
        """
        sentence = " ".join(f"word{i}" for i in range(300))
        text = (sentence + " ") * 100
        share, n_tok = sg.ShannonAnalyzer.top_token_share(text)
        assert share < sg.DILUTION_SHARE and n_tok > 10_000

        bits, red, _ = sg.ShannonAnalyzer.information_volume(text)
        assert red <= sg.VOLUME_REDUNDANCY_FLOOR
        assert bits < sg.VOLUME_BLOCK_BITS, "repetition is not new information"

        d = gate.evaluate(_msg(payload={"text": text}))
        assert "payload_redundancy" in d.reasons
        assert d.decision != "pass"

    def test_top_token_share_still_flags_gross_padding(self, gate):
        """The rule the review asked for by name, kept and still enforced."""
        d = gate.evaluate(_msg(payload={"text": "ping " * 200 + "alpha beta"}))
        assert "payload_dilution" in d.reasons
        assert d.decision != "pass"

    def test_volume_observe_mode_records_but_changes_no_verdict(
        self, gate, monkeypatch
    ):
        monkeypatch.setattr(sg, "VOLUME_MODE", "observe")
        d = gate.evaluate(_msg(payload={"output": _blob()}))
        assert "information_volume_block" in d.reasons   # measured + recorded
        assert d.bits_total > 400_000                    # number is on the row
        assert d.decision == "pass"                      # but not enforced

    def test_volume_off_mode_computes_no_reasons(self, gate, monkeypatch):
        monkeypatch.setattr(sg, "VOLUME_MODE", "off")
        d = gate.evaluate(_msg(payload={"output": _blob()}))
        assert not any("volume" in r or "redundancy" in r for r in d.reasons)
        assert d.decision == "pass"

    def test_dilution_guard_no_longer_depends_on_the_attestation_knob(
        self, gate, monkeypatch
    ):
        """SHANNON_ATTEST=off used to silently disarm the padding guard too,
        because the dilution escalation lived inside the attestation's enforce
        branch. One knob quietly switching off an unrelated check is the same
        silent no-op this file keeps being bitten by."""
        monkeypatch.setattr(sg, "ATTEST_MODE", "off")
        d = gate.evaluate(_msg(payload={"text": "ping " * 200 + "alpha beta"}))
        assert "payload_dilution" in d.reasons
        assert d.decision == "flagged"

    def test_oversized_payload_is_refused_not_measured(self, gate, tmp_path):
        """FAIL CLOSED on size: a payload past the ingest bound is refused
        before any measurement, and the refusal is on the audit row. Measuring
        it would be unbounded CPU on an attacker-chosen string."""
        huge = {"text": "a" * (sg.MAX_PAYLOAD_BYTES + 1000)}
        d = gate.evaluate(_msg(payload=huge))
        assert d.reasons == ["payload_oversize"]
        assert d.decision == "blocked"
        con = sqlite3.connect(str(tmp_path / "attest.db"))
        row = con.execute(
            "SELECT gate_decision, gate_reasons FROM agent_messages "
            "ORDER BY id DESC LIMIT 1"
        ).fetchone()
        con.close()
        assert row[0] == "blocked" and "payload_oversize" in row[1]

    def test_oversized_payload_is_refused_at_ingest_on_the_control_plane_too(
        self, tmp_path
    ):
        """An ingest refusal must beat EVERY dispatch branch, including the
        approval control plane, which is otherwise deliberately never blocked.
        A frame the gate refused to process must not be able to resolve a
        human approval on its way out."""
        db_path = tmp_path / "oversize.db"
        resp = _socket_roundtrip(db_path, {
            "agent_id": "science", "task_id": "t1",
            "message_type": "approval_response",
            "payload": {"approved": True, "interaction_id": "ask-1",
                        "pad": "a" * (sg.MAX_PAYLOAD_BYTES + 1000)},
        })
        assert resp["error"] == "payload_too_large"
        assert resp["decision"] == "blocked"
        assert resp["type"] != "approval_ack"

    def test_volume_never_fires_on_the_operators_real_traffic(self, gate):
        """False-positive floor. Every distinct payload SHAPE in the operator's
        real history is far under VOLUME_MIN_BYTES, so none of this can fire on
        the traffic the human actually reads."""
        real = [
            {"message": "Grok Build: demo status at 23:38:33", "step": 1,
             "source": "inject_agent_updates"},
            {"approval_needed": True, "prompt": "Dock 1G9V?",
             "interaction_id": "ask-sci-1"},
            {"approval_needed": True,
             "prompt": "Apply canary config for Astex Arm A?",
             "text": "Apply canary config for Astex Arm A?",
             "interaction_id": "ask-science-e2e-1784779386"},
            {"text": "clipboard-derived task text", "event": "ingest",
             "source": "cmd_d"},
            {"text": "hi"},
        ]
        for payload in real:
            d = gate.evaluate(_msg(payload=payload, shannon_H=0.0))
            assert not any(
                r.startswith(("information_volume", "payload_redundancy",
                              "payload_dilution", "unscored_", "payload_oversize"))
                for r in d.reasons
            ), (payload, d.reasons)


# ══════════════════════════════════════════════════════════════════════════════
# W2 / W3 — NO KEY AND NO NESTING MAY ESCAPE SCORING
# ══════════════════════════════════════════════════════════════════════════════

class TestNothingEscapesScoring:
    def test_metadata_key_cannot_hide_a_payload(self, gate):
        """The residual of the first W2 fix.

        The scored-key ALLOWLIST was replaced with a metadata DENYLIST — but
        the denylist was an unconditional skip, so `hash` (a metadata key)
        excluded its value from scoring at any length. {"hash": <60 kB>} was
        never token-scored and never volume-scored; the only thing that looked
        at it was the 0.30-weighted character term.

        Length is what separates a label from a payload.
        """
        payload = {"hash": _blob()}
        assert "hash" in sg.METADATA_KEYS
        d = gate.evaluate(_msg(payload=payload))
        assert d.decision == "blocked", (d.decision, d.reasons)
        assert "oversized_metadata_field" in d.reasons
        assert sg.ShannonAnalyzer.scored_text(payload) != ""

    def test_id_suffix_key_cannot_hide_a_payload(self, gate):
        """Same hole through the `*_id` rule rather than the explicit list."""
        payload = {"result_id": _blob()}
        d = gate.evaluate(_msg(payload=payload))
        assert d.decision == "blocked", (d.decision, d.reasons)
        assert sg.ShannonAnalyzer.scored_text(payload) != ""

    def test_short_metadata_values_are_still_labels(self):
        """The other half: the fix must not start scoring real identifiers.

        This is the check that keeps the operator's approval traffic clean —
        an interaction id is not content and must not be measured as if it
        were.
        """
        base = sg.ShannonAnalyzer.scored_text({"text": "hello world"})
        with_ids = sg.ShannonAnalyzer.scored_text({
            "text": "hello world", "interaction_id": "ask-9f3c",
            "message_id": "m-1", "task_id": "t-2", "source": "cmd_d",
            "hash": "9f3c1a7b", "version": "1.4.2",
        })
        assert base == with_ids

    def test_unknown_key_carrying_a_long_string_is_scored(self):
        """'An unrecognised key carrying a long string must be scored, never
        ignored.' The decoy that scored 1.326 and passed."""
        real = " ".join(f"secret{i}" for i in range(400))
        decoy = {"output": "ok ok", "result_body": real}
        assert real in sg.ShannonAnalyzer.scored_text(decoy)

    def test_nested_strings_are_scored_at_every_container_shape(self):
        """W3, pinned independently of W2: dicts, lists, tuples, and lists of
        dicts, under both known and unknown keys."""
        real = " ".join(f"secret{i}" for i in range(40))
        for payload in (
            {"content": {"text": real}},
            {"content": [real]},
            {"a": {"b": {"c": {"output": real}}}},
            {"rows": [{"cell": [{"v": real}]}]},
            {"unknown": ({"deep": real},)},
        ):
            assert real in sg.ShannonAnalyzer.scored_text(payload), payload
            assert sg.ShannonAnalyzer.combined_entropy_ex(payload)[1] > 5.0, payload

    def test_walk_truncation_fails_closed(self, gate):
        """Nesting past the walk bound leaves strings unmeasured. Returning a
        partial measurement as if it were complete is the fail-OPEN answer; the
        gate records that it did not see everything and refuses to pass."""
        node: dict = {"payload": "deep secret content"}
        for _ in range(sg.WALK_MAX_DEPTH + 4):
            node = {"n": node}
        content = sg.ShannonAnalyzer.scan(node)
        assert content.truncated
        d = gate.evaluate(_msg(payload=node))
        assert "unscored_truncated" in d.reasons
        assert d.decision != "pass"

    def test_a_normal_payload_is_never_marked_truncated(self):
        assert not sg.ShannonAnalyzer.scan(
            {"text": "hi", "nested": {"a": {"b": ["x", "y"]}}}
        ).truncated


# ══════════════════════════════════════════════════════════════════════════════
# R1 — CHUNKING DEFEATS A PER-STRING BOUND
#
# METADATA_MAX_LEN bounds each string ON ITS OWN and nothing bounded the sum,
# so 500 metadata-keyed fields of 128 legal characters were 500 legal labels
# and one 64 kB payload. Every hop skipped its own field as "obviously a
# label"; scored_text came back EMPTY; n_bytes was 0; the volume rule — the one
# statistic that exists precisely to be extensive — never ran at all. The
# content reassembles at the consumer and the audit row says bits_total = 0.
#
# The closure is an AGGREGATE: label bytes are charged to the volume
# measurement (always), and crossing SHANNON_LABEL_BUDGET_BYTES (4096) or
# SHANNON_LABEL_BUDGET_COUNT (64) is recorded and costs the message its pass.
# ══════════════════════════════════════════════════════════════════════════════

def _chunked(n_fields: int = 500, chunk_len: int = 128,
             alphabet: str = "") -> dict:
    """`n_fields` metadata-keyed fields, each individually a LEGAL label.

    Every value is <= METADATA_MAX_LEN, so the per-string rule has no
    objection to any of them. Deterministic: seeded RNG, no wall clock.
    """
    rng = random.Random(20260724)
    alphabet = alphabet or (string.ascii_letters + string.digits + "+/")
    return {
        f"chunk{i:03d}_id": "".join(rng.choice(alphabet) for _ in range(chunk_len))
        for i in range(n_fields)
    }


def _prose_chunked(n_fields: int = 500, chunk_len: int = 128) -> dict:
    """Same shape, but ordinary compressible prose rather than a random blob.

    This is the harder case: prose compresses, so it cannot lean on the block
    threshold. It exists to pin the primitive fact the residual named — the
    gate MEASURED NOTHING — independently of any threshold.
    """
    rng = random.Random(20260725)
    words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot",
             "golf", "hotel", "india", "juliet"]
    out = {}
    for i in range(n_fields):
        s = ""
        while len(s) < chunk_len:
            s += rng.choice(words) + " "
        out[f"shard{i:03d}_id"] = s[:chunk_len]
    return out


class TestChunkingCannotDefeatThePerStringBound:
    def test_the_aggregate_of_legal_labels_is_measured_at_all(self, gate):
        """THE RESIDUAL, in its most primitive form.

        Observed before the fix, on this exact payload:

            500 x 128 legal-label chars  ->  scored_text == ""
                                         ->  bits_total  == 0.0
                                         ->  reasons carried no volume rule

        64 kB reassembles at the consumer and the audit row records that the
        gate measured ZERO bits. Every threshold argument downstream is moot
        while the measurement itself is empty, so this test asserts on the
        measurement, not on a verdict.
        """
        payload = _prose_chunked()
        content = sg.ShannonAnalyzer.scan(payload)

        assert content.text == "", "each field is still individually a label"
        assert content.label_count == 500
        assert content.label_bytes >= 60_000

        d = gate.evaluate(_msg(payload=payload))
        assert d.bits_total > 0.0, "the gate measured nothing at all"
        assert "label_aggregate" in d.reasons
        assert any(r.startswith("information_volume") for r in d.reasons), d.reasons
        assert d.decision != "pass"

    def test_chunked_high_information_content_is_blocked(self, gate):
        """The same move with content that does not compress: 64 kB of
        incompressible payload, split into 500 individually-legal labels, is
        the byte-for-byte equivalent of the blob in
        test_whitespace_free_blob_cannot_score_zero — and must land in the
        same place."""
        d = gate.evaluate(_msg(payload=_chunked()))
        assert "information_volume_block" in d.reasons, d.reasons
        assert d.decision == "blocked"
        assert d.bits_total >= sg.VOLUME_BLOCK_BITS

    def test_chunking_buys_the_sender_nothing(self, gate):
        """The property that actually closes the hole: splitting a payload
        across label fields must cost what shipping it inline costs. If
        chunking is cheaper by any meaningful factor it is still an evasion,
        just a slower one."""
        blob = _blob(60_000)
        inline = gate.evaluate(_msg(payload={"output": blob}))
        chunks = {f"part{i:03d}_id": blob[i * 120:(i + 1) * 120]
                  for i in range(500)}
        split = gate.evaluate(_msg(agent_id="codex", payload=chunks))
        assert split.bits_total >= 0.5 * inline.bits_total, (
            split.bits_total, inline.bits_total)
        assert split.decision == inline.decision == "blocked"

    def test_the_label_byte_budget_fires_on_bytes_alone(self, gate):
        """Few fields, each legal, aggregating past SHANNON_LABEL_BUDGET_BYTES.
        The COUNT budget cannot see this one — 40 fields is unremarkable — so
        the byte budget has to carry it on its own."""
        payload = {f"blk{i}_id": ("z" * 120) + f"{i:03d}" for i in range(40)}
        content = sg.ShannonAnalyzer.scan(payload)
        assert content.label_count <= sg.LABEL_BUDGET_COUNT, "count budget is clear"
        assert content.label_bytes > sg.LABEL_BUDGET_BYTES
        assert content.label_overflow
        assert "label_aggregate" in gate.evaluate(_msg(payload=payload)).reasons

    def test_the_label_count_budget_fires_on_count_alone(self):
        """Many fields, few bytes: past SHANNON_LABEL_BUDGET_COUNT while the
        byte budget is nowhere near. The two bounds are independent on
        purpose."""
        payload = {f"n{i}_id": f"v{i}" for i in range(sg.LABEL_BUDGET_COUNT + 1)}
        content = sg.ShannonAnalyzer.scan(payload)
        assert content.label_bytes < sg.LABEL_BUDGET_BYTES, "byte budget is clear"
        assert content.label_overflow

    def test_repeated_labels_are_one_string_of_information(self):
        """Deduplication, for the same reason the scored text dedups: 500
        copies of one id is one id's worth of information. Charging it 500
        times would flag well-behaved clients that repeat a task id."""
        payload = {f"k{i}_id": "same-identifier" for i in range(500)}
        content = sg.ShannonAnalyzer.scan(payload)
        assert content.label_count == 1
        assert content.label_bytes == len("same-identifier")

    def test_an_id_heavy_but_honest_payload_is_not_blocked(self, gate):
        """FALSE-POSITIVE FLOOR, and the reason label bytes are charged to
        VOLUME rather than promoted into the token stream: promoting 60 short
        identifiers into the scored text puts H_token at log2(60) = 5.9, i.e.
        over H_BLOCK_THRESHOLD, and every id-heavy client blocks on its first
        message."""
        payload = {"text": "batch complete",
                   **{f"target{i}_id": f"1G9V{i:03d}" for i in range(60)}}
        d = gate.evaluate(_msg(payload=payload))
        assert d.decision != "blocked", d.reasons
        assert "information_volume_block" not in d.reasons

    def test_label_aggregate_alone_costs_a_clean_message_its_pass(
        self, gate, monkeypatch
    ):
        """Crossing a budget is visible BELOW the volume thresholds — that is
        the whole point of having budgets as well as accounting. Isolated here
        by shrinking the count budget, so nothing but the budget can fire."""
        monkeypatch.setattr(sg, "LABEL_BUDGET_COUNT", 2)
        payload = {"text": WORK_TEXT, "a_id": "x1", "b_id": "x2", "c_id": "x3"}
        d = gate.evaluate(_msg(payload=payload))
        assert d.computed_H < sg.H_THRESHOLD, "otherwise H is doing the work"
        assert "label_aggregate" in d.reasons
        assert d.decision == "flagged"

    def test_label_aggregate_never_blocks_on_its_own(self, gate, monkeypatch):
        """A chatty-but-honest client is SEEN, not stopped. Only the volume
        rule — which measures the bytes rather than counting the fields — may
        block."""
        monkeypatch.setattr(sg, "LABEL_BUDGET_COUNT", 2)
        d = gate.evaluate(_msg(payload={"text": WORK_TEXT, "a_id": "x1",
                                        "b_id": "x2", "c_id": "x3"}))
        assert d.decision != "blocked"

    def test_label_aggregate_is_observable_and_demotable(self, gate, monkeypatch):
        """Observe-only, per the knob convention: recorded on the audit row,
        no verdict change. SHANNON_VOLUME is the knob because this IS a volume
        rule — an aggregate on the extensive statistic."""
        monkeypatch.setattr(sg, "LABEL_BUDGET_COUNT", 2)
        monkeypatch.setattr(sg, "VOLUME_MODE", "observe")
        payload = {"text": WORK_TEXT, "a_id": "x1", "b_id": "x2", "c_id": "x3"}
        d = gate.evaluate(_msg(payload=payload))
        assert "label_aggregate" in d.reasons
        assert d.decision == "pass"

    def test_label_aggregate_off_mode_is_a_true_no_op(self, gate, monkeypatch):
        monkeypatch.setattr(sg, "LABEL_BUDGET_COUNT", 2)
        monkeypatch.setattr(sg, "VOLUME_MODE", "off")
        d = gate.evaluate(_msg(payload={"text": WORK_TEXT, "a_id": "x1",
                                        "b_id": "x2", "c_id": "x3"}))
        assert "label_aggregate" not in d.reasons
        assert d.decision == "pass"

    def test_the_aggregate_byte_bound_stops_the_walk_and_fails_closed(self, gate):
        """The bound a chunker actually has to beat. A payload that clears the
        1 MB ingest bound can still carry more leaf bytes than the walk will
        measure; when it does, the walk STOPS, and an incomplete measurement is
        never a pass."""
        payload = {f"f{i}": "q" * 1000 + str(i) for i in range(600)}
        content = sg.ShannonAnalyzer.scan(payload)
        assert content.total_bytes <= sg.WALK_MAX_TOTAL_BYTES + 1001
        assert content.truncated
        d = gate.evaluate(_msg(payload=payload))
        assert "unscored_truncated" in d.reasons
        assert d.decision != "pass"

    def test_the_total_string_count_bound_fails_closed(self):
        """The count analogue: more distinct strings than the walk will visit
        is the same statement — strings exist that were not measured."""
        payload = {f"f{i}": f"s{i}" for i in range(sg.WALK_MAX_STRINGS + 50)}
        assert sg.ShannonAnalyzer.scan(payload).truncated

    def test_the_operators_real_traffic_is_untouched_by_the_aggregate(self, gate):
        """FALSE-POSITIVE FLOOR for R1. The real history's biggest label load
        is three fields totalling 26 bytes — 20x under the count budget and
        150x under the byte budget."""
        real = [
            {"message": "Grok Build: demo status at 23:38:33", "step": 1,
             "source": "inject_agent_updates"},
            {"approval_needed": True, "prompt": "Dock 1G9V?",
             "interaction_id": "ask-sci-1"},
            {"text": "clipboard-derived task text", "event": "ingest",
             "source": "cmd_d"},
        ]
        for payload in real:
            d = gate.evaluate(_msg(payload=payload, shannon_H=0.0))
            assert "label_aggregate" not in d.reasons, (payload, d.reasons)
            assert not sg.ShannonAnalyzer.scan(payload).label_overflow


# ══════════════════════════════════════════════════════════════════════════════
# R2 — NON-STRING LEAVES ARE INFORMATION
#
# The walk collected `str` leaves only, so every non-string carrier was a free
# ride. A list of 40 000 ints in 0..255 is a 40 kB file with the quotes taken
# off: it scored nothing, carried no volume, and passed with an empty reason
# list. The gate does NOT decode it — interpreting attacker-chosen bytes is a
# parser and a parser is an attack surface — it packs each leaf to canonical
# bytes and charges the INFORMATION CONTENT through the same zlib estimator.
# ══════════════════════════════════════════════════════════════════════════════

class TestNonStringLeavesAreScored:
    @staticmethod
    def _bytes_list(n: int = 40_000) -> list[int]:
        rng = random.Random(20260726)
        return [rng.randrange(256) for _ in range(n)]

    def test_a_list_of_byte_values_is_a_file_with_the_quotes_taken_off(self, gate):
        """Observed before the fix: decision 'pass', reasons [], bits_total
        0.0, for 40 kB of unpredictable content."""
        d = gate.evaluate(_msg(payload={"kind": "status",
                                        "data": self._bytes_list()}))
        assert d.bits_total >= sg.VOLUME_BLOCK_BITS, d.bits_total
        assert "information_volume_block" in d.reasons
        assert d.decision == "blocked"

    def test_a_numeric_array_under_a_metadata_key_is_still_counted(self, gate):
        """R1 and R2 compose: the metadata skip never applied to non-strings,
        but a reviewer should not have to work that out from the source."""
        d = gate.evaluate(_msg(payload={"hash": self._bytes_list()}))
        assert "information_volume_block" in d.reasons
        assert d.decision == "blocked"

    def test_deeply_nested_lists_of_small_ints_are_counted(self, gate):
        """Nesting is not a carrier the volume rule loses track of."""
        flat = self._bytes_list()
        nested = [flat[i:i + 100] for i in range(0, len(flat), 100)]
        d = gate.evaluate(_msg(payload={"rows": [{"cells": nested}]}))
        assert "information_volume_block" in d.reasons
        assert d.decision == "blocked"

    def test_a_float_array_carries_information_too(self, gate):
        rng = random.Random(20260727)
        d = gate.evaluate(_msg(payload={
            "scores": [rng.random() for _ in range(20_000)]}))
        assert d.bits_total >= sg.VOLUME_BLOCK_BITS, d.bits_total
        assert d.decision == "blocked"

    def test_a_predictable_array_is_near_free(self, gate):
        """FALSE-POSITIVE FLOOR, and the reason the estimator is a compressor
        rather than a byte count: 200 000 zeros are 200 kB of nothing. A rule
        that charged them their length would block every zero-padded tensor an
        honest client ever sends."""
        d = gate.evaluate(_msg(payload={"data": [0] * 200_000}))
        assert "information_volume_block" not in d.reasons, d.reasons
        assert d.bits_total < sg.VOLUME_FLAG_BITS

    def test_ordinary_numeric_payloads_are_untouched(self, gate):
        """The docking traffic this gate actually carries: a handful of floats
        and ints must not acquire a reason string."""
        d = gate.evaluate(_msg(payload={
            "text": "docking complete", "cf_value": -42.7, "rmsd": 1.83,
            "poses": [1, 2, 3, 4, 5], "converged": True, "note": None,
        }))
        assert not any(r.startswith(("information_volume", "payload_redundancy",
                                     "label_aggregate")) for r in d.reasons), d.reasons

    def test_packing_is_deterministic_and_decodes_nothing(self):
        """DETERMINISM, asserted rather than assumed: the same payload must
        pack to the same bytes on every machine and every run — no clock, no
        hash randomisation, no dict-ordering dependence beyond the payload's
        own."""
        payload = {"a": [1, 2, 3], "b": 3.5, "c": True, "d": None,
                   "e": [[7, 8], [9]]}
        first = sg.ShannonAnalyzer.scan(payload)
        second = sg.ShannonAnalyzer.scan(payload)
        assert first.volume_extra == second.volume_extra
        assert first.nonstring_bytes == second.nonstring_bytes > 0
        # b"\x03" is int 3 packed; nothing here is an attempt to READ the
        # numbers as text, a path, or anything else.
        assert b"\x01\x02\x03" in first.volume_extra

    def test_a_huge_integer_cannot_cost_unbounded_work(self):
        """FAIL CLOSED on cost: one absurd int must not turn the walk into an
        unbounded allocation."""
        content = sg.ShannonAnalyzer.scan({"n": 1 << 200_000})
        assert content.nonstring_bytes <= sg.NUMERIC_LEAF_MAX_BYTES


# ══════════════════════════════════════════════════════════════════════════════
# W4 — OUT-OF-BAND POINTERS
#
# Measured content and delivered content are disjoint when the message carries
# a reference. No threshold on the measured side can fix that, so the gate does
# the only honest thing: it records that it did not see the content, and it
# refuses to certify the message. It never dereferences anything.
# ══════════════════════════════════════════════════════════════════════════════

class _DereferenceTripwire:
    """Records every ATTEMPT to reach the filesystem or the network.

    R4 — WHY THIS IS NOT A `def boom(): raise`.
    The predecessor patched `open` to raise an AssertionError and asserted
    nothing afterwards, so it detected the SIDE EFFECT of a dereference: the
    test failed only if the exception propagated. A validator defeated it with
    three characters of exception handling —

        try:  open(pointer)
        except Exception:  pass

    — which attempts the read, swallows the sentinel, and leaves the suite
    green. The record kept here OUTLIVES the exception: the test inspects
    ``calls`` after ``evaluate()`` has returned, so no amount of exception
    handling inside the gate can hide the attempt. The sentinel still raises
    as well, so an implementation that does NOT swallow also fails loudly at
    the point of the attempt.

    Deterministic: patches only, no real I/O, no clock, no network, no daemon.
    """

    _ROUTES = (
        ("builtins", "open"),
        ("io", "open"),
        ("io", "open_code"),
        ("os", "open"),
        ("os", "fdopen"),
        ("PATH", "open"),
        ("PATH", "read_text"),
        ("PATH", "read_bytes"),
        ("urllib.request", "urlopen"),
        ("urllib.request", "urlretrieve"),
        ("SOCKET_CLASS", "connect"),
        ("socket", "create_connection"),
        ("subprocess", "Popen"),
        ("subprocess", "run"),
    )

    def __init__(self) -> None:
        self.calls: list[str] = []
        self._saved: list[tuple[object, str, object]] = []

    def _targets(self):
        import builtins
        import io
        import os
        import socket
        import subprocess
        import urllib.request

        table = {
            "builtins": builtins, "io": io, "os": os, "socket": socket,
            "subprocess": subprocess, "urllib.request": urllib.request,
            "PATH": Path, "SOCKET_CLASS": socket.socket,
        }
        for mod, attr in self._ROUTES:
            obj = table[mod]
            if hasattr(obj, attr):
                yield f"{mod}.{attr}", obj, attr

    def __enter__(self) -> _DereferenceTripwire:
        for name, obj, attr in self._targets():
            self._saved.append((obj, attr, getattr(obj, attr)))

            def sentinel(*a, _name=name, **k):
                # RECORD FIRST. Everything after this line can be swallowed;
                # this line cannot be.
                self.calls.append(_name)
                raise AssertionError(
                    f"the gate must never dereference a pointer ({_name})"
                )

            setattr(obj, attr, sentinel)
        return self

    def __exit__(self, *exc) -> None:
        for obj, attr, original in reversed(self._saved):
            setattr(obj, attr, original)
        self._saved.clear()


class TestOutOfBandPointers:
    def test_the_demonstrated_artifact_handoff_cannot_pass(self, gate):
        """Observed: scored 2.7123, decision 'pass', reasons []."""
        payload = {"output": "analysis complete see artifact",
                   "artifact_path": "/tmp/exfil.bin"}
        d = gate.evaluate(_msg(payload=payload))
        assert d.computed_H < sg.H_THRESHOLD, "still low-entropy — that is the point"
        assert "unscored_pointer" in d.reasons
        assert d.decision != "pass"

    @pytest.mark.parametrize("payload", [
        {"output": "done", "url": "https://example.invalid/a"},
        {"output": "done", "download_url": "http://x.invalid/y"},
        {"output": "see file:///etc/passwd for details"},
        {"output": "results in /var/tmp/run42/out.json"},
        {"output": "written to ~/reports/final.md"},
        {"output": "cf. ./relative/path.txt"},
        {"output": "s3://bucket/key/obj.bin"},
        {"summary": "ok", "artifact_id": "a7f3c9d2"},     # opaque id, key says pointer
        {"summary": "ok", "pose_file": "1G9V_pose.pdb"},
        {"nested": {"rows": [{"blob_ref": "sha256:abcd"}]}},   # any depth
    ])
    def test_pointer_shapes_are_all_caught(self, gate, payload):
        d = gate.evaluate(_msg(payload=payload))
        assert "unscored_pointer" in d.reasons, payload
        assert d.decision != "pass", payload

    @pytest.mark.parametrize("text", [
        "we should do this and/or that",
        "the run took 24/7 of wall time",
        "I/O bound, not CPU bound",
        "ratio was 3/4 across the board",
        "Apply canary config for Astex Arm A?",
    ])
    def test_ordinary_prose_is_not_a_pointer(self, text):
        """FALSE-POSITIVE FLOOR. A gate that misfires gets switched off, and a
        path rule that matches every slash in English prose misfires on every
        message. The path branch is anchored to start-of-string-or-whitespace
        precisely so these do not match."""
        assert not sg.ShannonAnalyzer.is_pointer(None, text), text

    @pytest.mark.parametrize("payload", [
        # R3 widening — shapes the pattern matcher used to walk straight past.
        {"output": "saved to reports/final.md"},          # bare relative path
        {"output": "see src/main.py for the change"},     # bare, mid-sentence
        {"output": r"copied to C:\Users\me\secret.txt"},  # Windows drive path
        {"output": "copied to C:/Users/me/secret.txt"},   # Windows, forward
        {"output": r"on \\fileserver\share\dump.bin"},    # UNC / SMB
        {"output": "inline data:text/plain;base64,QUJDREVG"},   # data: URI
        {"output": "held at blob:9f3ca71b22d0"},          # opaque blob: scheme
        {"summary": "ok", "ref": "a7f3c9d2"},             # key: ref
        {"summary": "ok", "location": "opaque-handle-1"},  # key: location
        {"summary": "ok", "src": "handle-2"},             # key: src
        {"summary": "ok", "href": "handle-3"},            # key: href
        {"summary": "ok", "uri": "handle-4"},             # key: uri
        {"summary": "ok", "result_paths": ["h5", "h6"]},  # plural key
        {"summary": "ok", "output_dir": "run42"},         # *_dir suffix
        {"summary": "ok", "export_bucket": "b7"},         # *_bucket suffix
    ])
    def test_widened_pointer_shapes_are_caught(self, gate, payload):
        d = gate.evaluate(_msg(payload=payload))
        assert "unscored_pointer" in d.reasons, payload
        assert d.decision != "pass", payload

    @pytest.mark.parametrize("text", [
        # The widening must not cost the false-positive floor. Every one of
        # these is ordinary prose that mentions a slash, a colon or a dot.
        "we measured 60 km/h. Then we stopped",
        "the ratio was 1/2.5 across the runs",
        "the split was 50/50 overall",
        "date 2024/01/15 was the cutoff",
        "TCP/IP is fine here",
        "see the read/write path",
        "his/her choice, n/a either way",
        "input/output latency dropped 5%",
        "cost/benefit analysis of Arm B",
        "run 3 of 4 done",
        "data: 42 rows returned",
        "Grok Build: demo status at 23:38:33",
        "clipboard-derived task text",
        "Dock 1G9V?",
    ])
    def test_the_widening_did_not_break_the_false_positive_floor(self, text):
        assert not sg.ShannonAnalyzer.is_pointer(None, text), text

    def test_the_docstring_does_not_overclaim_the_heuristic(self):
        """R3, the half that is not code. A pattern matcher documented as if it
        were a decision procedure is worse than no documentation: the next
        reader budgets no residual risk for it. The docstring must say what it
        IS and enumerate what it MISSES, and this test is what stops the
        honesty being edited back out.
        """
        doc = sg.ShannonAnalyzer.is_pointer.__doc__ or ""
        assert "HEURISTIC" in doc
        assert "BLIND SPOTS" in doc
        for missed in ("extensionless", "opaque identifier", "encoded"):
            assert missed in doc.lower(), missed
        # …and it must still say the thing that is NOT a heuristic.
        assert "dereference" in doc

    def test_the_gate_never_dereferences_anything(self, gate):
        """THE POLICY, ENFORCED BY TEST — not just documented.

        No URL is fetched (that would make the gate an SSRF primitive on a
        trusted host, and would make this very suite depend on the network) and
        no local path is opened (bounded reads still lose the TOCTOU race
        between measuring the file and delivering the reference). Any future
        edit that adds a fetch or an open on the scoring path fails here.

        R4: this asserts on the ATTEMPT, not on its side effect. See
        _DereferenceTripwire for why the previous side-effect form was
        defeatable by three characters of exception handling.
        """
        with _DereferenceTripwire() as tw:
            d = gate.evaluate(_msg(payload={
                "output": "see https://example.invalid/payload and /etc/hosts",
                "artifact_path": "/tmp/does/not/exist.bin",
                "windows": r"C:\Users\me\secret.txt",
                "bare": "reports/final.md",
            }))
        assert tw.calls == [], f"the gate reached for: {tw.calls}"
        assert "unscored_pointer" in d.reasons

    def test_a_swallowed_dereference_cannot_hide_from_the_tripwire(
        self, gate, monkeypatch
    ):
        """R4 — THE TEST THAT TESTS THE TEST.

        A validator defeated the previous no-dereference test in one line: the
        sentinel only RAISED, so an injected read wrapped in

            try:  open(value)
            except Exception:  pass

        was attempted, the AssertionError was swallowed by the injected code's
        own except clause, and the suite stayed green while the gate read
        attacker-chosen paths. Here that exact injection is performed on the
        scoring path, and the tripwire must still name it.

        Deterministic and offline: the path opened is one that does not exist,
        so the outcome does not depend on the filesystem — which is precisely
        why counting side effects was never going to work.
        """
        original = sg.ShannonAnalyzer.__dict__["is_pointer"].__func__

        def leaky(key, value):
            try:                                   # the demonstrated defeat
                with open("/tmp/shannon-does-not-exist.bin", "rb"):
                    pass
            except Exception:                      # noqa: BLE001 — the point
                pass
            return original(key, value)

        monkeypatch.setattr(sg.ShannonAnalyzer, "is_pointer", staticmethod(leaky))

        with _DereferenceTripwire() as tw:
            gate.evaluate(_msg(payload={"output": "x", "artifact_path": "/etc/hosts"}))

        assert tw.calls, (
            "a swallowed dereference stayed invisible — the tripwire is "
            "measuring side effects again, not attempts"
        )
        assert any("open" in c for c in tw.calls), tw.calls

    @pytest.mark.parametrize("reach", [
        "builtins.open", "io.open", "os.open", "pathlib.Path.open",
        "pathlib.Path.read_text", "pathlib.Path.read_bytes",
        "urllib.request.urlopen", "socket.socket.connect",
        "socket.create_connection", "subprocess.Popen",
    ])
    def test_every_dereference_route_is_actually_covered(self, reach):
        """A tripwire is only worth what it patches. Each route below is
        exercised directly, so a future edit that drops one from the patch list
        fails here rather than silently narrowing the guarantee."""
        import builtins
        import io
        import os
        import socket
        import subprocess
        import urllib.request

        mod, _, attr = reach.rpartition(".")
        obj = {
            "builtins": builtins, "io": io, "os": os,
            "pathlib.Path": Path, "urllib.request": urllib.request,
            "socket": socket, "socket.socket": socket.socket,
            "subprocess": subprocess,
        }[mod]

        with _DereferenceTripwire() as tw:
            try:
                if attr in ("read_text", "read_bytes", "open") and obj is Path:
                    getattr(Path("/tmp/x"), attr)()
                elif obj is socket.socket:
                    socket.socket().connect(("127.0.0.1", 9))
                elif attr == "create_connection":
                    socket.create_connection(("127.0.0.1", 9))
                elif attr == "Popen":
                    subprocess.Popen(["/bin/true"])
                elif attr == "urlopen":
                    urllib.request.urlopen("http://127.0.0.1:9/")
                elif attr == "open" and obj is os:
                    os.open("/tmp/x", os.O_RDONLY)
                else:
                    getattr(obj, attr)("/tmp/x")
            except Exception:                      # noqa: BLE001 — swallowed
                pass
        assert tw.calls, f"{reach} is not covered by the tripwire"

    def test_an_unresolvable_pointer_is_treated_exactly_like_any_other(self, gate):
        """'Unresolvable' is not a special case, because the gate never tries
        to resolve anything. A path that does not exist and one that does are
        the same statement to this gate: content it did not see."""
        exists = gate.evaluate(_msg(agent_id="codex",
                                    payload={"o": "x", "path": "/etc/hosts"}))
        missing = gate.evaluate(_msg(agent_id="cowork",
                                     payload={"o": "x", "path": "/no/such/file"}))
        assert exists.decision == missing.decision != "pass"
        assert exists.reasons == missing.reasons

    def test_unscored_observe_mode_records_but_changes_no_verdict(
        self, gate, monkeypatch
    ):
        monkeypatch.setattr(sg, "UNSCORED_MODE", "observe")
        d = gate.evaluate(_msg(payload={"output": "done", "artifact_path": "/tmp/a"}))
        assert "unscored_pointer" in d.reasons        # on the audit row
        assert d.decision == "pass"                   # no verdict change

    def test_unscored_block_mode_refuses_delivery(self, gate, monkeypatch):
        monkeypatch.setattr(sg, "UNSCORED_MODE", "block")
        d = gate.evaluate(_msg(payload={"output": "done", "artifact_path": "/tmp/a"}))
        assert d.decision == "blocked"

    def test_unscored_off_mode_is_a_true_no_op(self, gate, monkeypatch):
        monkeypatch.setattr(sg, "UNSCORED_MODE", "off")
        d = gate.evaluate(_msg(payload={"output": "done", "artifact_path": "/tmp/a"}))
        assert not any(r.startswith("unscored_") for r in d.reasons)
        assert d.decision == "pass"

    def test_flag_mode_still_delivers_the_message(self, tmp_path):
        """`flag` must not be an outage. Only `blocked` stops traffic, so a
        pointer-carrying message is marked and forwarded — the distinction an
        operator needs before turning anything on."""
        resp = _socket_roundtrip(tmp_path / "ptr.db", {
            "agent_id": "science", "task_id": "t1", "message_type": "result",
            "payload": {"output": "done", "artifact_path": "/tmp/a.bin"},
        })
        assert resp["type"] == "gate_response"
        assert resp["decision"] == "flagged"


# ══════════════════════════════════════════════════════════════════════════════
# D3 / D5 — LIVENESS BOOKKEEPING MUST NOT DESTROY LIVE STATE
# ══════════════════════════════════════════════════════════════════════════════

# The Pill's orphan rule, copied verbatim from
# Pill/Sources/PillCore/GateDBReader.swift:pendingAsks. An ask matching this is
# dropped from the HUD and retracted from the user's other devices.
_ORPHAN_SQL = """
    SELECT CASE WHEN a.disconnected_at IS NOT NULL
                 AND a.disconnected_at > i.created_at_ns THEN 1 ELSE 0 END
    FROM agent_interactions i
    LEFT JOIN agents a ON a.agent_id = i.agent_id
    WHERE i.interaction_id = ?
"""


class TestRestartDoesNotRetractApprovals:
    def _seed(self, db_path: Path) -> tuple[sg.AuditDB, int]:
        db = sg.AuditDB(db_path)
        now = time.time_ns()
        db.upsert_agent("science", "active", now - 10_000_000_000)
        db.upsert_interaction("ask-live", "science", "Dock 1G9V?", "pending")
        con = sqlite3.connect(str(db_path))
        con.execute(
            "UPDATE agent_interactions SET created_at_ns = ? "
            "WHERE interaction_id = 'ask-live'",
            (now - 5_000_000_000,),
        )
        con.commit()
        con.close()
        return db, now

    def test_restart_does_not_orphan_a_pending_approval(self, tmp_path):
        """D3 — every approval outstanding across a gate restart disappeared.

        `mark_all_disconnected` stamped `now` on every open row. The pill reads
        `disconnected_at > created_at_ns` as "the asking agent left", so a
        restart retracted every pending ask from the HUD and from the user's
        other devices while `agent_interactions.status` still said 'pending':
        the question became simultaneously unanswered and unanswerable, and
        nothing in the UI said why.
        """
        db_path = tmp_path / "d3.db"
        db, now = self._seed(db_path)

        assert db.mark_all_disconnected(now) == 1        # row still closed out

        con = sqlite3.connect(str(db_path))
        orphaned = con.execute(_ORPHAN_SQL, ("ask-live",)).fetchone()[0]
        row = con.execute(
            "SELECT status, disconnected_at FROM agents WHERE agent_id='science'"
        ).fetchone()
        con.close()

        assert orphaned == 0, "a gate restart must not retract a live approval"
        assert row[0] == "idle"                          # not reported as live
        assert row[1] is not None                        # and properly closed out

    def test_restart_still_closes_out_agents_with_no_pending_ask(self, tmp_path):
        """The behaviour that must survive the fix: a leftover 'connected' row
        from a crashed run is still closed, or the pill shows agents as live
        that have not existed since the last reboot."""
        db_path = tmp_path / "d3b.db"
        db = sg.AuditDB(db_path)
        now = time.time_ns()
        db.upsert_agent("codex", "active", now - 10_000_000_000)

        assert db.mark_all_disconnected(now) == 1
        con = sqlite3.connect(str(db_path))
        row = con.execute(
            "SELECT status, disconnected_at FROM agents WHERE agent_id='codex'"
        ).fetchone()
        con.close()
        assert row[0] == "idle" and row[1] == now

    def test_an_answered_ask_does_not_hold_the_stamp_back(self, tmp_path):
        """Only UNANSWERED questions backdate the stamp. A resolved ask is
        history and must not keep an agent looking recently-connected."""
        db_path = tmp_path / "d3c.db"
        db, now = self._seed(db_path)
        db.resolve_interaction("ask-live", True)

        db.mark_all_disconnected(now)
        con = sqlite3.connect(str(db_path))
        val = con.execute(
            "SELECT disconnected_at FROM agents WHERE agent_id='science'"
        ).fetchone()[0]
        con.close()
        assert val == now

    def test_mark_all_disconnected_works_before_any_interaction_exists(
        self, tmp_path
    ):
        """agent_interactions is created lazily, so a gate whose very first
        action is a restart must not trip over its absence."""
        db_path = tmp_path / "d3d.db"
        db = sg.AuditDB(db_path)
        db.upsert_agent("codex", "active", time.time_ns())
        assert db.mark_all_disconnected(time.time_ns()) == 1


class TestReconnectDoesNotKillTheLiveConnection:
    def test_superseded_handler_does_not_deregister_the_new_connection(
        self, tmp_path
    ):
        """D5 — the disconnect `finally` popped whatever was registered under
        the agent id, not the connection it belonged to.

        A reconnect replaces the registry entry while the OLD handler is still
        unwinding, so the old handler removed the NEW, live connection from
        `_connections` and stamped `disconnected_at` on an agent that was at
        that moment connected and talking. The agent vanished from every
        reader and stopped receiving broadcasts. Which handler unwinds first is
        a scheduling detail, so the bug was intermittent.
        """
        socket_path = f"/tmp/shannon_d5_{uuid.uuid4().hex[:8]}.sock"
        db_path = tmp_path / "d5.db"

        async def scenario():
            hub = sg.AgentHub(db_path=db_path)
            hub.gate = sg.ShannonGate(hub.db)
            hub._lock = asyncio.Lock()
            hub._shutdown = asyncio.Event()
            server = await asyncio.start_unix_server(
                hub._handle_socket_conn, path=socket_path
            )
            async with server:
                # First connection registers.
                r1, w1 = await asyncio.open_unix_connection(socket_path)
                w1.write((json.dumps({"agent_id": "science"}) + "\n").encode())
                await w1.drain()
                await r1.readline()

                # Second connection for the SAME id replaces it in the registry.
                r2, w2 = await asyncio.open_unix_connection(socket_path)
                w2.write((json.dumps({"agent_id": "science"}) + "\n").encode())
                await w2.drain()
                await r2.readline()
                live = hub._connections["science"]

                # Now the first, superseded connection drops.
                w1.close()
                for _ in range(200):                 # deterministic: poll state,
                    await asyncio.sleep(0)           # never sleep on a clock
                    if w1.is_closing():
                        break
                await asyncio.sleep(0.05)

                registered = hub._connections.get("science")

                # The live connection must still work end to end.
                w2.write((json.dumps({
                    "agent_id": "science", "task_id": "t1",
                    "message_type": "status", "payload": {"text": "still here"},
                }) + "\n").encode())
                await w2.drain()
                reply = json.loads((await r2.readline()).decode())

                # Read the registry row WHILE the second connection is still
                # open — after w2.close() its own handler stamps the row and
                # the assertion would be vacuous.
                con = sqlite3.connect(str(db_path))
                stamp = con.execute(
                    "SELECT disconnected_at FROM agents WHERE agent_id='science'"
                ).fetchone()[0]
                con.close()

                w2.close()
                return registered is live, reply, stamp

        try:
            still_registered, reply, stamp = asyncio.run(scenario())
        finally:
            Path(socket_path).unlink(missing_ok=True)

        assert still_registered, \
            "the superseded handler deregistered the live connection"
        assert reply["type"] == "gate_response"
        assert stamp is None, \
            "a live, talking agent was stamped disconnected by an old handler"


# ══════════════════════════════════════════════════════════════════════════════
# Migration safety on a real, pre-existing database
# ══════════════════════════════════════════════════════════════════════════════

class TestMigration:
    def test_legacy_database_is_migrated_in_place(self, tmp_path):
        """Built from the schema as it shipped BEFORE this change, then opened
        with the new gate — the shape of the operator's own agent_hub.db."""
        db_path = tmp_path / "legacy.db"
        con = sqlite3.connect(str(db_path))
        con.executescript("""
            CREATE TABLE agents (
                agent_id TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'idle',
                connected_at INTEGER, last_seen_ns INTEGER NOT NULL DEFAULT 0,
                disconnected_at INTEGER, task_id TEXT DEFAULT '',
                message_count INTEGER DEFAULT 0, entropy_score REAL DEFAULT 0.0,
                task_summary TEXT DEFAULT '', auth_method TEXT DEFAULT 'socket_secret'
            );
            CREATE TABLE agent_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                received_at_ns INTEGER NOT NULL, agent_id TEXT NOT NULL,
                task_id TEXT NOT NULL, message_type TEXT NOT NULL, message_id TEXT,
                payload_json TEXT NOT NULL, timestamp_ns INTEGER,
                self_H REAL, self_conf REAL, gate_H REAL, gate_D REAL,
                gate_H_temporal REAL, gate_decision TEXT, gate_reasons TEXT
            );
            INSERT INTO agents (agent_id) VALUES ('science');
            INSERT INTO agent_messages
                (received_at_ns, agent_id, task_id, message_type, payload_json,
                 self_H, gate_H, gate_decision, gate_reasons)
            VALUES (1, 'science', 't', 'approval_needed',
                    '{"prompt": "Dock 1G9V?"}', 1.0, 4.58, 'flagged',
                    '["H_mismatch(self=1.00,gate=4.58)"]');
        """)
        con.commit()
        con.close()

        db = sg.AuditDB(db_path)                      # migrates in place
        con = sqlite3.connect(str(db_path))
        acols = {r[1] for r in con.execute("PRAGMA table_info(agents)")}
        mcols = {r[1] for r in con.execute("PRAGMA table_info(agent_messages)")}
        preserved = con.execute(
            "SELECT gate_H, gate_reasons FROM agent_messages"
        ).fetchone()
        con.close()

        assert {"calib_n", "calib_bias", "calib_score", "calib_offences",
                "calib_silence", "calib_state", "calib_updated_ns",
                "heartbeat_ns"} <= acols
        assert {"gate_H_token", "self_divergence", "self_residual",
                "attested"} <= mcols
        assert preserved[0] == 4.58                   # history untouched
        assert "H_mismatch" in preserved[1]

        # ...and the migrated DB is immediately usable end to end.
        gate = sg.ShannonGate(db)
        assert gate.evaluate(_msg(shannon_H=LIE_CLAIM)).decision == "flagged"
        assert db.calibration_report()

    def test_migration_is_idempotent(self, tmp_path):
        p = tmp_path / "twice.db"
        sg.AuditDB(p)
        sg.AuditDB(p)
        sg.ShannonGate(sg.AuditDB(p)).evaluate(_msg())

    def test_ledger_upserts_when_no_agents_row_exists(self, tmp_path):
        """The HTTP transport never called upsert_agent, so a reputation score
        cached on `agents` would have had a hole the size of that transport."""
        db = sg.AuditDB(tmp_path / "http.db")
        sg.ShannonGate(db).evaluate(_msg(agent_id="grok_build", shannon_H=LIE_CLAIM))
        con = sqlite3.connect(str(tmp_path / "http.db"))
        row = con.execute(
            "SELECT calib_n, calib_state FROM agents WHERE agent_id='grok_build'"
        ).fetchone()
        con.close()
        assert row and row[0] == 1


# ══════════════════════════════════════════════════════════════════════════════
# Operator surface
# ══════════════════════════════════════════════════════════════════════════════

class TestOperatorSurface:
    def test_calibration_report_separates_a_broken_client_from_a_liar(self, tmp_path):
        db = sg.AuditDB(tmp_path / "rep.db")
        gate = sg.ShannonGate(db)
        biased = WORK_H_TOKEN / (2 ** 0.45)
        for _ in range(12):
            gate.evaluate(_msg(agent_id="dispatch", shannon_H=biased))
        for _ in range(12):
            gate.evaluate(_msg(agent_id="grok_build", shannon_H=LIE_CLAIM))

        rep = {r["agent_id"]: r for r in db.calibration_report()}
        assert rep["dispatch"]["calib_state"] in ("calibrated", "calibrating")
        assert rep["grok_build"]["calib_state"] == "untrusted"
        assert rep["grok_build"]["calib_score"] > rep["dispatch"]["calib_score"]

    def test_knobs_follow_the_shannon_convention(self):
        for name in ("SHANNON_ATTEST", "SHANNON_ATTEST_FLOOR",
                     "SHANNON_ATTEST_MARGIN", "SHANNON_UNATTESTED_FLOOR",
                     "SHANNON_ATTEST_BONUS", "SHANNON_ECHO",
                     "SHANNON_STRICT_TYPES",
                     # R1 / R2 aggregate bounds.
                     "SHANNON_LABEL_BUDGET_BYTES", "SHANNON_LABEL_BUDGET_COUNT",
                     "SHANNON_WALK_MAX_TOTAL_BYTES",
                     "SHANNON_NUMERIC_LEAF_MAX_BYTES"):
            assert name in Path(sg.__file__).read_text()

    def test_new_aggregate_defaults_are_stated_and_safe(self):
        """Defaults are part of the contract: an operator reading the module
        docstring must find the same numbers the code uses."""
        assert sg.LABEL_BUDGET_BYTES == 4096
        assert sg.LABEL_BUDGET_COUNT == 64
        assert sg.WALK_MAX_TOTAL_BYTES == 524_288
        assert sg.NUMERIC_LEAF_MAX_BYTES == 8192
        # …and the aggregate bound must sit UNDER the ingest bound, or it can
        # never fire.
        assert sg.WALK_MAX_TOTAL_BYTES < sg.MAX_PAYLOAD_BYTES
        doc = sg.__doc__ or ""
        for stated in ("SHANNON_LABEL_BUDGET_BYTES (4096)",
                       "SHANNON_LABEL_BUDGET_COUNT (64)",
                       "SHANNON_WALK_MAX_TOTAL_BYTES=524288"):
            assert stated in doc, stated

    def test_default_thresholds_are_unchanged(self):
        assert sg.H_THRESHOLD == pytest.approx(3.5)
        assert sg.H_BLOCK_THRESHOLD == pytest.approx(5.0)
        assert sg.D_THRESHOLD == pytest.approx(1.8)
