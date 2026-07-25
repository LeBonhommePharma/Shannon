"""Tests for hub/agent_manager.py — pure plans + CLI dry-run (no live gate)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import agent_manager as am
from agent_identity import HANDRAIL_AGENT_IDS, IDENTITIES


class TestNormalizeAgentId:
    @pytest.mark.parametrize(
        "raw,want",
        [
            ("Grok Build", "grok_build"),
            ("grok", "grok_build"),
            ("claude", "claude_code"),
            ("Claude Science", "science"),
            ("sci", "science"),
            ("cowork", "cowork"),
            ("dispatch", "dispatch"),
            ("codex", "codex"),
            ("design", "design"),
            ("OpenCode", "opencode"),
            ("oc", "opencode"),
            ("dataset", "dataset_runner"),
        ],
    )
    def test_aliases(self, raw, want):
        assert am.normalize_agent_id(raw) == want

    def test_unknown_slug_passthrough(self):
        assert am.normalize_agent_id("my_custom_bot") == "my_custom_bot"


class TestLifecyclePlans:
    def test_spawn_plan(self):
        p = am.plan_spawn("science", "task_a", reason="flexaidds")
        assert p.action == "spawn"
        assert p.agent_id == "science"
        assert p.task_id == "task_a"
        assert p.message_type == "status"
        assert p.payload["lifecycle"] == "spawn"
        assert "Science" in p.payload["message"] or "science" in p.payload["message"].lower()
        d = p.as_dict()
        assert d["label"]
        assert d["notes"]

    def test_control_plan(self):
        p = am.plan_control("codex", "t1", "compiling", details={"step": 1})
        assert p.action == "control"
        assert p.payload["message"] == "compiling"
        assert p.payload["step"] == 1

    def test_kill_plan(self):
        p = am.plan_kill("claude_code", "t1", reason="done")
        assert p.action == "kill"
        assert p.payload["lifecycle"] == "kill"
        assert p.payload["status"] == "offline"

    def test_monitor_plan(self):
        p = am.plan_monitor()
        assert p.action == "monitor"
        assert p.payload["query_type"] == "agent_list"

    def test_ask_plan(self):
        p = am.plan_ask("science", "t1", "Approve?")
        assert p.message_type == "approval_needed"
        assert p.payload["prompt"] == "Approve?"

    def test_send_result_plan(self):
        p = am.plan_send_result(
            "dataset_runner", "t1", {"cf_value": -3.2, "target_id": "1ACJ"}
        )
        assert p.message_type == "result"
        assert p.payload["cf_value"] == -3.2


class TestRoster:
    def test_handrail_includes_design_and_opencode(self):
        ids = {r["id"] for r in am.handrail_roster()}
        assert "design" in ids
        assert "opencode" in ids
        assert "science" in ids
        assert "grok_build" in ids
        for aid in HANDRAIL_AGENT_IDS:
            assert aid in IDENTITIES
            assert aid in ids

    def test_format_monitor_report_empty(self):
        text = am.format_monitor_report([], [])
        assert "connected" in text.lower()
        assert "(none)" in text

    def test_format_monitor_report_with_data(self):
        text = am.format_monitor_report(
            ["science", "codex"],
            [{"agent_id": "science", "message_type": "status", "payload": {"message": "hi"}}],
        )
        assert "science" in text
        assert "status" in text


class TestCLIDryRun:
    def test_roster_cli(self, capsys):
        rc = am.main(["roster", "--json"])
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["ok"] is True
        assert any(r["id"] == "opencode" for r in data["handrail"])

    def test_spawn_dry_run(self, capsys):
        rc = am.main(["spawn", "science", "--task", "t_dry", "--dry-run", "--json"])
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["action"] == "spawn"
        assert data["agent_id"] == "science"

    def test_kill_dry_run(self, capsys):
        rc = am.main(
            ["kill", "codex", "--task", "t_dry", "--dry-run", "--json"]
        )
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["action"] == "kill"

    def test_monitor_dry_run(self, capsys):
        rc = am.main(["monitor", "--dry-run", "--json"])
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["action"] == "monitor"

    def test_gate_status_absent_socket(self, tmp_path, capsys):
        sock = tmp_path / "no.sock"
        rc = am.main(["gate-status", "--socket", str(sock), "--json"])
        assert rc == 2
        data = json.loads(capsys.readouterr().out)
        assert data["gate_up"] is False


class TestIdentitiesShipped:
    def test_design_and_opencode_in_identities(self):
        assert "design" in IDENTITIES
        assert "opencode" in IDENTITIES
        assert IDENTITIES["design"].display_name == "Claude Design"
        assert IDENTITIES["opencode"].display_name == "OpenCode"
