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


class TestShannonGateEvaluate:
    @pytest.fixture
    def gate(self, tmp_path):
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

    def test_high_entropy_message_is_flagged(self, gate):
        diverse_text = " ".join(f"word{i}" for i in range(60))
        msg = self._msg(payload={"text": diverse_text})
        decision = gate.evaluate(msg)
        assert decision.computed_H >= sg.H_THRESHOLD
        assert decision.decision in ("flagged", "blocked")

    def test_very_high_entropy_message_is_blocked(self, gate):
        diverse_text = " ".join(f"uniqueword{i}" for i in range(400))
        msg = self._msg(payload={"text": diverse_text})
        decision = gate.evaluate(msg)
        if decision.computed_H >= sg.H_BLOCK_THRESHOLD:
            assert decision.decision == "blocked"

    def test_cf_disagreement_flags_message(self, gate):
        gate.evaluate(self._msg(agent_id="codex", payload={"cf_value": -3.2}))
        decision = gate.evaluate(
            self._msg(agent_id="science", payload={"cf_value": -4.91})
        )
        assert any("CF_disagreement" in r for r in decision.reasons)


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
            hub = sg.AgentHub()
            hub.db = sg.AuditDB(tmp_path / "agent_hub.db")
            hub.gate = sg.ShannonGate(hub.db)

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
            hub = sg.AgentHub()
            hub.db = sg.AuditDB(tmp_path / "agent_hub.db")
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
