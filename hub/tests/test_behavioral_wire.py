"""P1.1 / P0.3: BehavioralMonitor is the primary gate signal (default enforce).

SHANNON_BEHAVIOR=observe must never change the gate decision.
Enforce may escalate pass→flagged only when the behavioural score is high.
Default mode is enforce (polarity fix — see ENTROPY_AUDIT_2026-07-23.md).
"""

from __future__ import annotations

from pathlib import Path

import pytest

import shannon_gate as sg


@pytest.fixture
def db_path(tmp_path: Path) -> Path:
    return tmp_path / "behavior_wire.db"


@pytest.fixture
def gate(db_path: Path) -> sg.ShannonGate:
    return sg.ShannonGate(sg.AuditDB(db_path))


def _msg(
    agent_id: str = "science",
    message_type: str = "status",
    text: str = "ok",
    **over,
) -> sg.AgentMessage:
    base = dict(
        agent_id=agent_id,
        task_id="t1",
        message_type=message_type,
        payload={"text": text},
        timestamp_ns=1_000_000_000,
        shannon_H=0.0,
        confidence=1.0,
    )
    base.update(over)
    return sg.AgentMessage(**base)


class TestBehavioralWireSmoke:
    def test_evaluate_a_few_messages_no_crash(self, gate: sg.ShannonGate):
        """Construct ShannonGate, evaluate a few messages — must not crash."""
        types = ("status", "result", "status", "code_suggestion", "status")
        decisions = []
        for i, mt in enumerate(types):
            d = gate.evaluate(
                _msg(
                    message_type=mt,
                    timestamp_ns=(i + 1) * 1_000_000_000,
                    text=f"ping {i}",
                )
            )
            decisions.append(d)
            assert d.decision in ("pass", "flagged", "blocked")
            assert isinstance(d.reasons, list)
            assert isinstance(d.computed_H, float)

    def test_observe_mode_keeps_valid_decision(self, gate: sg.ShannonGate, monkeypatch):
        """Default/observe: behaviour annotations never invalidate the decision."""
        monkeypatch.setattr(sg, "BEHAVIOR_MODE", "observe")
        # Rebuild gate so _behavior is present under observe.
        g = sg.ShannonGate(gate.db)
        d = g.evaluate(_msg(text="hello world"))
        assert d.decision in ("pass", "flagged", "blocked")
        # Reasons may or may not contain behavior_observe (warmup / score).
        # Decision string must remain one of the three legal values.
        assert all(isinstance(r, str) for r in d.reasons)

    def test_behavior_off_skips_monitor(self, db_path: Path, monkeypatch):
        monkeypatch.setattr(sg, "BEHAVIOR_MODE", "off")
        g = sg.ShannonGate(sg.AuditDB(db_path))
        assert g._behavior is None
        d = g.evaluate(_msg())
        assert d.decision in ("pass", "flagged", "blocked")
        assert not any(r.startswith("behavior_observe:") for r in d.reasons)

    def test_observe_logs_reason_without_changing_pass(
        self, db_path: Path, monkeypatch
    ):
        """Novel action after baseline → behavior_observe reason; decision stays pass."""
        monkeypatch.setattr(sg, "BEHAVIOR_MODE", "observe")
        monkeypatch.setattr(sg, "BEHAVIOR_FLAG_SCORE", 0.5)
        monkeypatch.setattr(sg, "H_THRESHOLD", 99.0)
        monkeypatch.setattr(sg, "H_BLOCK_THRESHOLD", 99.0)
        monkeypatch.setattr(sg, "ATTEST_MODE", "off")
        monkeypatch.setattr(sg, "VOLUME_MODE", "off")
        monkeypatch.setattr(sg, "UNSCORED_MODE", "off")
        g = sg.ShannonGate(sg.AuditDB(db_path))
        if g._behavior is None:
            pytest.skip("BehavioralMonitor not importable")

        t = 0
        for _ in range(40):
            t += 1_000_000_000
            g.evaluate(_msg(message_type="status", timestamp_ns=t, text="ok"))
        t += 1_000_000_000
        d = g.evaluate(
            _msg(message_type="result", timestamp_ns=t, text="ok")
        )
        assert any(r.startswith("behavior_observe:") for r in d.reasons), d.reasons
        assert d.decision == "pass"

    def test_enforce_escalates_pass_to_flagged(
        self, db_path: Path, monkeypatch
    ):
        monkeypatch.setattr(sg, "BEHAVIOR_MODE", "enforce")
        monkeypatch.setattr(sg, "BEHAVIOR_FLAG_SCORE", 0.5)
        monkeypatch.setattr(sg, "H_THRESHOLD", 99.0)
        monkeypatch.setattr(sg, "H_BLOCK_THRESHOLD", 99.0)
        monkeypatch.setattr(sg, "ATTEST_MODE", "off")
        monkeypatch.setattr(sg, "VOLUME_MODE", "off")
        monkeypatch.setattr(sg, "UNSCORED_MODE", "off")
        g = sg.ShannonGate(sg.AuditDB(db_path))
        if g._behavior is None:
            pytest.skip("BehavioralMonitor not importable")

        t = 0
        for _ in range(40):
            t += 1_000_000_000
            g.evaluate(_msg(message_type="status", timestamp_ns=t, text="ok"))
        t += 1_000_000_000
        d = g.evaluate(
            _msg(message_type="result", timestamp_ns=t, text="ok")
        )
        assert any(r.startswith("behavior_observe:") for r in d.reasons), d.reasons
        assert d.decision == "flagged"

    def test_gate_scores_reexported(self):
        """Modularization must keep shannon_gate.registry_entropy_score public."""
        assert callable(sg.registry_entropy_score)
        assert callable(sg.is_human_approval_request)
        d = sg.GateDecision(
            decision="pass", reasons=[], computed_H=2.5, computed_D=0.0
        )
        assert sg.registry_entropy_score(d) == 2.5

    def test_registry_prefers_behavior_entropy_over_text_proxy(self):
        """HUD polarity: low behavioural H is danger; prefer it over verbosity H."""
        d = sg.GateDecision(
            decision="flagged",
            reasons=[],
            computed_H=6.0,  # verbose text proxy (would look "healthy" if inverted)
            computed_D=0.0,
            behavior_entropy_bits=1.2,  # collapsed repertoire
            behavior_n_events=8,
        )
        assert sg.registry_entropy_score(d) == pytest.approx(1.2)

    def test_registry_ignores_single_event_behavior_h(self):
        """First action always has H=0 — do not overwrite computed_H with that."""
        d = sg.GateDecision(
            decision="pass",
            reasons=[],
            computed_H=3.2,
            computed_D=0.0,
            behavior_entropy_bits=0.0,
            behavior_n_events=1,
        )
        assert sg.registry_entropy_score(d) == pytest.approx(3.2)

    def test_registry_prefers_core_collapse_h(self):
        d = sg.GateDecision(
            decision="flagged",
            reasons=[],
            computed_H=5.0,
            computed_D=0.0,
            behavior_entropy_bits=3.0,
            core_collapse_H=2.1,
        )
        assert sg.registry_entropy_score(d) == pytest.approx(2.1)

    def test_default_behavior_mode_is_enforce(self):
        assert sg.BEHAVIOR_MODE == "enforce"
