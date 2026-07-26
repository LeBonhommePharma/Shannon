import math
from pathlib import Path

import pytest

import shannon_gate as sg


class TestTokenEntropy:
    def test_empty_string_is_zero(self):
        assert sg.ShannonAnalyzer.token_entropy("") == 0.0

    def test_single_token_is_zero(self):
        assert sg.ShannonAnalyzer.token_entropy("hello") == 0.0

    def test_uniform_distribution_matches_formula(self):
        # 4 distinct tokens, each appearing once -> H = log2(4) = 2.0
        H = sg.ShannonAnalyzer.token_entropy("alpha beta gamma delta")
        assert H == pytest.approx(2.0, abs=1e-9)

    def test_repeated_tokens_lower_entropy_than_diverse(self):
        H_repeat = sg.ShannonAnalyzer.token_entropy("cat cat cat cat")
        H_diverse = sg.ShannonAnalyzer.token_entropy("cat dog bird fish")
        assert H_repeat == 0.0
        assert H_diverse > H_repeat

    def test_manual_entropy_formula(self):
        text = "a a b"
        # tokens: a,a,b -> p(a)=2/3 p(b)=1/3
        expected = -((2 / 3) * math.log2(2 / 3) + (1 / 3) * math.log2(1 / 3))
        assert sg.ShannonAnalyzer.token_entropy(text) == pytest.approx(expected, abs=1e-9)


class TestStructuralEntropy:
    def test_short_payload_is_zero(self):
        assert sg.ShannonAnalyzer.structural_entropy({}) == 0.0

    def test_nonempty_payload_is_positive(self):
        H = sg.ShannonAnalyzer.structural_entropy({"a": 1, "b": "hello world"})
        assert H > 0.0


class TestCombinedEntropy:
    def test_falls_back_to_structural_when_no_text_fields(self):
        payload = {"cf_value": -3.2, "rmsd": 1.1}
        H = sg.ShannonAnalyzer.combined_entropy(payload)
        expected = round(sg.ShannonAnalyzer.structural_entropy(payload), 4)
        assert H == pytest.approx(expected, abs=1e-9)

    def test_weighted_combination_of_text_and_struct(self):
        payload = {"text": "alpha beta gamma delta"}
        H_text = sg.ShannonAnalyzer.token_entropy("alpha beta gamma delta")
        H_struct = sg.ShannonAnalyzer.structural_entropy(payload)
        expected = round(0.70 * H_text + 0.30 * H_struct, 4)
        assert sg.ShannonAnalyzer.combined_entropy(payload) == expected


class TestDisagreementEntropy:
    def test_single_agent_returns_zero(self):
        assert sg.ShannonAnalyzer.disagreement_entropy({"a": -3.2}) == 0.0

    def test_identical_values_low_disagreement(self):
        D = sg.ShannonAnalyzer.disagreement_entropy({"a": -3.2, "b": -3.2})
        assert D == pytest.approx(1.0, abs=1e-3)  # two equal weights -> log2(2)

    def test_large_spread_increases_disagreement_relative_to_close_values(self):
        D_close = sg.ShannonAnalyzer.disagreement_entropy({"a": -3.20, "b": -3.21})
        D_far = sg.ShannonAnalyzer.disagreement_entropy({"a": -3.2, "b": -4.91})
        assert D_far < D_close  # softmax pushes weight onto the more negative CF


class TestTemporalEntropy:
    def test_short_history_returns_zero(self):
        assert sg.ShannonAnalyzer.temporal_entropy(["result", "status"]) == 0.0

    def test_uniform_types_higher_entropy_than_single_type(self):
        uniform = sg.ShannonAnalyzer.temporal_entropy(["a", "b", "c", "d"])
        single = sg.ShannonAnalyzer.temporal_entropy(["a", "a", "a", "a"])
        assert uniform > single
        assert single == 0.0


class TestGateThresholds:
    def test_default_thresholds(self):
        assert sg.H_THRESHOLD == pytest.approx(3.5)
        assert sg.H_BLOCK_THRESHOLD == pytest.approx(5.0)
        assert sg.D_THRESHOLD == pytest.approx(1.8)
        # Primary signal is behavioural enforce; text proxy is observe-only.
        assert sg.BEHAVIOR_MODE == "enforce"
        assert sg.TEXT_PROXY_MODE == "observe"


class TestShannonGateEvaluate:
    @pytest.fixture
    def gate(self, tmp_path, monkeypatch):
        # Isolate polarity tests from attestation / volume side-effects.
        monkeypatch.setattr(sg, "ATTEST_MODE", "off")
        monkeypatch.setattr(sg, "VOLUME_MODE", "off")
        monkeypatch.setattr(sg, "UNSCORED_MODE", "off")
        db = sg.AuditDB(tmp_path / "agent_hub.db")
        return sg.ShannonGate(db)

    def _msg(self, **overrides):
        base = dict(
            agent_id="science",
            task_id="task_1",
            message_type="status",
            payload={"text": "short update"},
            timestamp_ns=0,
            shannon_H=0.0,
            confidence=0.9,
        )
        base.update(overrides)
        return sg.AgentMessage(**base)

    def test_low_entropy_message_passes(self, gate):
        msg = self._msg(payload={"text": "ok"})
        decision = gate.evaluate(msg)
        assert decision.decision == "pass"

    def test_high_text_proxy_h_does_not_block_by_default(self, gate):
        """Verbosity is not danger — high combined_H must not primary-block."""
        diverse_text = " ".join(f"word{i}" for i in range(60))
        msg = self._msg(payload={"text": diverse_text})
        decision = gate.evaluate(msg)
        assert decision.computed_H >= sg.H_THRESHOLD
        # Observe-only proxy may annotate; must not force blocked.
        assert decision.decision != "blocked"
        assert any(
            r.startswith("text_proxy_observe:") for r in decision.reasons
        ) or decision.decision == "pass"

    def test_text_proxy_enforce_restores_legacy_high_h_block(self, tmp_path, monkeypatch):
        monkeypatch.setattr(sg, "TEXT_PROXY_MODE", "enforce")
        monkeypatch.setattr(sg, "BEHAVIOR_MODE", "off")
        monkeypatch.setattr(sg, "ATTEST_MODE", "off")
        monkeypatch.setattr(sg, "VOLUME_MODE", "off")
        monkeypatch.setattr(sg, "UNSCORED_MODE", "off")
        gate = sg.ShannonGate(sg.AuditDB(tmp_path / "legacy.db"))
        diverse_text = " ".join(f"uniqueword{i}" for i in range(400))
        decision = gate.evaluate(self._msg(payload={"text": diverse_text}))
        if decision.computed_H >= sg.H_BLOCK_THRESHOLD:
            assert decision.decision == "blocked"
            assert any("H_hard_block" in r for r in decision.reasons)

    def test_short_dangerous_not_autopassed_by_low_word_h(self, gate):
        """rm -rf style text has low word-H; must not be 'safe' via proxy alone.

        With text proxy demoted, short text is not blocked by H — but it also
        is not *certified* by low H. Decision is not forced to pass by the
        proxy; volume/attest/behavior still apply. Here other modes are off so
        pass is allowed, and computed_H is recorded (low), never inverted into
        a 'healthy high-H' pass signal.
        """
        decision = gate.evaluate(self._msg(payload={"text": "rm -rf /"}))
        assert decision.computed_H < sg.H_THRESHOLD
        # Must not carry a legacy H_hard_block / H_flag reason from high proxy.
        assert not any(r.startswith("H_hard_block") or r.startswith("H_flag(")
                       for r in decision.reasons)

    def test_cf_disagreement_flags_message(self, gate):
        gate.evaluate(self._msg(agent_id="codex", payload={"cf_value": -3.2}))
        decision = gate.evaluate(
            self._msg(agent_id="science", payload={"cf_value": -4.91})
        )
        assert any("CF_disagreement" in r for r in decision.reasons)


class TestPolarityAndPrimarySignal:
    """Low behavioural anomaly free / high diversity = healthy; KL spike = danger."""

    def _msg(self, agent_id, message_type, ts, text="ok"):
        return sg.AgentMessage(
            agent_id=agent_id,
            task_id="t1",
            message_type=message_type,
            payload={"text": text},
            timestamp_ns=ts,
            shannon_H=0.0,
            confidence=1.0,
        )

    def test_anomaly_after_baseline_flags_under_enforce(self, tmp_path, monkeypatch):
        monkeypatch.setattr(sg, "BEHAVIOR_MODE", "enforce")
        monkeypatch.setattr(sg, "BEHAVIOR_FLAG_SCORE", 0.5)
        monkeypatch.setattr(sg, "TEXT_PROXY_MODE", "off")
        monkeypatch.setattr(sg, "ATTEST_MODE", "off")
        monkeypatch.setattr(sg, "VOLUME_MODE", "off")
        monkeypatch.setattr(sg, "UNSCORED_MODE", "off")
        gate = sg.ShannonGate(sg.AuditDB(tmp_path / "pol.db"))
        if gate._behavior is None:
            pytest.skip("BehavioralMonitor unavailable")
        t = 0
        for _ in range(40):
            t += 1_000_000_000
            gate.evaluate(self._msg("science", "status", t))
        t += 1_000_000_000
        d = gate.evaluate(self._msg("science", "result", t, text="done"))
        assert any(r.startswith("behavior_observe:") for r in d.reasons), d.reasons
        assert d.decision == "flagged"
        assert d.behavior_score >= 0.5
        # Registry polarity: prefers behavioural H (finite, >= 0).
        score = sg.registry_entropy_score(d)
        assert score >= 0.0
        assert math.isfinite(score)

    def test_diverse_action_sequence_not_flagged_by_entropy(self, tmp_path, monkeypatch):
        monkeypatch.setattr(sg, "BEHAVIOR_MODE", "enforce")
        monkeypatch.setattr(sg, "BEHAVIOR_FLAG_SCORE", 1.0)
        monkeypatch.setattr(sg, "TEXT_PROXY_MODE", "off")
        monkeypatch.setattr(sg, "ATTEST_MODE", "off")
        monkeypatch.setattr(sg, "VOLUME_MODE", "off")
        monkeypatch.setattr(sg, "UNSCORED_MODE", "off")
        gate = sg.ShannonGate(sg.AuditDB(tmp_path / "div.db"))
        if gate._behavior is None:
            pytest.skip("BehavioralMonitor unavailable")
        types = ("status", "result", "code_suggestion", "alert", "benchmark_update")
        t = 0
        last = None
        for i in range(50):
            t += 1_000_000_000
            last = gate.evaluate(
                self._msg("science", types[i % len(types)], t, text=f"ping {i}")
            )
        assert last is not None
        # Steady diverse repertoire should not raise a behaviour anomaly flag.
        assert not any(r.startswith("behavior_observe:") for r in last.reasons), last.reasons
        assert last.decision == "pass"
        assert last.behavior_entropy_bits is not None
        assert last.behavior_entropy_bits > 1.0  # high action-type H = healthy

    def test_core_logprobs_collapse_flags(self, tmp_path, monkeypatch):
        monkeypatch.setattr(sg, "BEHAVIOR_MODE", "off")
        monkeypatch.setattr(sg, "TEXT_PROXY_MODE", "off")
        monkeypatch.setattr(sg, "ATTEST_MODE", "off")
        monkeypatch.setattr(sg, "VOLUME_MODE", "off")
        monkeypatch.setattr(sg, "UNSCORED_MODE", "off")
        monkeypatch.setattr(sg, "CORE_COLLAPSE_H", 4.0)
        gate = sg.ShannonGate(sg.AuditDB(tmp_path / "core.db"))
        # Peaked distribution → low Shannon H (collapse).
        import math
        peaked = [0.0] + [-20.0] * 31  # logprobs: one token dominates
        d = gate.evaluate(
            sg.AgentMessage(
                agent_id="science",
                task_id="t",
                message_type="status",
                payload={"text": "x", "logprobs": peaked},
                timestamp_ns=1,
                shannon_H=0.0,
                confidence=1.0,
            )
        )
        assert d.core_collapse_H is not None
        assert d.core_collapse_H < 4.0
        assert d.decision == "flagged"
        assert any("core_collapse" in r for r in d.reasons)
        # Uniform logprobs → high H, no collapse flag.
        n = 32
        uni = [-math.log(n)] * n
        d2 = gate.evaluate(
            sg.AgentMessage(
                agent_id="science",
                task_id="t",
                message_type="status",
                payload={"text": "y", "logprobs": uni},
                timestamp_ns=2,
                shannon_H=0.0,
                confidence=1.0,
            )
        )
        assert d2.core_collapse_H is not None
        assert d2.core_collapse_H >= 4.0
        assert d2.decision == "pass"


class TestAuditDB:
    def test_log_and_read_message(self, tmp_path):
        db = sg.AuditDB(tmp_path / "agent_hub.db")
        msg = sg.AgentMessage(
            agent_id="science",
            task_id="t1",
            message_type="status",
            payload={"text": "hi"},
            timestamp_ns=1,
            shannon_H=0.0,
            confidence=1.0,
        )
        decision = sg.GateDecision(decision="pass", reasons=[], computed_H=0.1, computed_D=0.0)
        db.log_message(msg, decision)
        rows = db.get_recent_messages(limit=10)
        assert len(rows) == 1
        assert rows[0]["agent_id"] == "science"

    def test_cf_report_and_latest_lookup(self, tmp_path):
        db = sg.AuditDB(tmp_path / "agent_hub.db")
        db.log_cf_report("dataset_runner", "t1", "1ACJ", -3.217, 1.38, "pose.pdb")
        db.log_cf_report("science", "t1", "1ACJ", -3.221, 1.40, None)
        latest = db.get_latest_cf_per_agent("t1")
        assert latest["dataset_runner"] == pytest.approx(-3.217)
        assert latest["science"] == pytest.approx(-3.221)


class TestSocketServerBasics:
    """Basic request/response check against AgentHub's Unix socket server."""

    def test_unix_socket_registration_and_gate_response(self, tmp_path, monkeypatch):
        import asyncio
        import json as _json
        import uuid

        # AF_UNIX paths have a short max length (~104 bytes on macOS); pytest's
        # tmp_path can exceed that, so use a short path under /tmp instead.
        socket_path = f"/tmp/shannon_test_{uuid.uuid4().hex[:8]}.sock"
        monkeypatch.setattr(sg, "SOCKET_PATH", socket_path)

        async def scenario():
            hub = sg.AgentHub(db_path=tmp_path / "agent_hub.db")
            hub.gate = sg.ShannonGate(hub.db)
            # `run()` normally binds these to the running loop. Without them
            # `_handle_socket_conn` raises on `async with self._lock` the
            # instant it gets past registration, the connection is torn down
            # with nothing written, and the assertion below fails on an empty
            # readline — which reads like an environment problem ("something
            # else owns the socket") and is not one. This test has never
            # exercised the message loop; now it does.
            hub._lock = asyncio.Lock()
            hub._shutdown = asyncio.Event()

            server = await asyncio.start_unix_server(hub._handle_socket_conn, path=socket_path)
            async with server:
                reader, writer = await asyncio.open_unix_connection(socket_path)
                writer.write((_json.dumps({"agent_id": "science", "task_id": "t1"}) + "\n").encode())
                await writer.drain()

                welcome = _json.loads((await reader.readline()).decode())
                assert welcome["type"] == "welcome"
                assert welcome["agent_id"] == "science"

                writer.write((_json.dumps({
                    "agent_id": "science", "task_id": "t1",
                    "message_type": "status", "payload": {"text": "hi"},
                }) + "\n").encode())
                await writer.drain()

                response = _json.loads((await reader.readline()).decode())
                assert response["type"] == "gate_response"
                assert response["decision"] in ("pass", "flagged", "blocked")

                writer.close()

        try:
            asyncio.run(scenario())
        finally:
            Path(socket_path).unlink(missing_ok=True)

    def test_rejects_unknown_agent(self, tmp_path, monkeypatch):
        import asyncio
        import json as _json
        import uuid

        socket_path = f"/tmp/shannon_test_{uuid.uuid4().hex[:8]}.sock"
        monkeypatch.setattr(sg, "SOCKET_PATH", socket_path)

        async def scenario():
            hub = sg.AgentHub(db_path=tmp_path / "agent_hub.db")
            hub.gate = sg.ShannonGate(hub.db)

            server = await asyncio.start_unix_server(hub._handle_socket_conn, path=socket_path)
            async with server:
                reader, writer = await asyncio.open_unix_connection(socket_path)
                writer.write((_json.dumps({"agent_id": "mallory", "task_id": "t1"}) + "\n").encode())
                await writer.drain()

                raw = await reader.readline()
                data = _json.loads(raw.decode())
                assert "error" in data
                writer.close()

        try:
            asyncio.run(scenario())
        finally:
            Path(socket_path).unlink(missing_ok=True)
