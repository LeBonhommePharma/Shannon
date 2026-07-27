"""Shannon-owned FlexAIDdS campaign plans + dual-owner refusal (pure, no gate)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import agent_manager as am


class TestCampaignOwnership:
    def test_plan_has_task_phases_and_dataset_runner_owner(self):
        plan = am.plan_benchmark_campaign(
            "red-pair",
            task_id="flexaidds_redpair_20260726",
            owner="dataset_runner",
            analysts=["science"],
            coders=["claude_code", "codex"],
            coordinator="dispatch",
        )
        d = plan.as_dict()
        assert d["action"] == "campaign"
        assert d["ok"] is True
        assert d["refused"] is False
        assert d["task_id"] == "flexaidds_redpair_20260726"
        assert d["campaign"] == "red_pair"  # normalised Dataset name
        assert d["phases"] == ["A", "B0", "B"]
        assert d["owner_agent_id"] == "dataset_runner"
        assert d["owner_role"] in ("docking_owner", "owner")
        assert d["fabricated_entropy"] is None
        assert d["fabricated_cf"] is None
        # Owner + science + coders + coordinator
        agents = {x["agent_id"] for x in d["delegations"] if x.get("ok")}
        assert "dataset_runner" in agents
        assert "science" in agents
        assert "claude_code" in agents
        assert "codex" in agents
        assert "dispatch" in agents
        # Each ok delegation carries a spawn plan
        owner_d = next(x for x in d["delegations"] if x["agent_id"] == "dataset_runner")
        assert owner_d["plan"]["action"] == "spawn"
        assert owner_d["plan"]["task_id"] == "flexaidds_redpair_20260726"
        assert owner_d["plan"]["payload"].get("shannon_owned") is True

    def test_owner_alias_dr_resolves(self):
        plan = am.plan_benchmark_campaign(owner="dr", task_id="t1")
        assert plan.owner_agent_id == "dataset_runner"

    def test_auto_task_id_prefix(self):
        plan = am.plan_benchmark_campaign("astex")
        assert "flexaidds" in plan.task_id
        assert "astex" in plan.task_id
        assert plan.campaign == "astex"
        assert plan.task_id

    def test_known_dataset_campaign_aliases(self):
        assert am.normalize_campaign_name("red-pair") == "red_pair"
        assert am.normalize_campaign_name("astex85") == "astex"
        assert am.normalize_campaign_name("casf2016") == "casf"
        assert am.normalize_campaign_name("hap2") == "hap2"
        plan = am.plan_benchmark_campaign("astex85", task_id="flexaidds_astex_fixed")
        assert plan.campaign == "astex"
        assert plan.refused is False
        assert plan.as_dict()["ok"] is True
        assert plan.owner_agent_id == "dataset_runner"


class TestDualOwnerRefusal:
    def test_second_heavy_owner_refused_when_monitor_shows_owner(self):
        plan = am.plan_benchmark_campaign(
            task_id="flexaidds_redpair_20260726",
            owner="dataset_runner",
            monitor_connected=["dataset_runner", "science"],
        )
        d = plan.as_dict()
        assert d["refused"] is True
        assert d["ok"] is False
        assert d["existing_heavy_owner"] == "dataset_runner"
        assert "dual" in (d["refuse_reason"] or "").lower() or "owned" in (
            d["refuse_reason"] or ""
        ).lower()
        assert d["delegations"] == []

    def test_science_analyst_delegate_ok_while_owner_online(self):
        result = am.plan_delegate(
            "science",
            "flexaidds_redpair_20260726",
            monitor_connected=["dataset_runner"],
        )
        assert result["ok"] is True
        assert result["refused"] is False
        assert result["agent_id"] == "science"
        assert result["plan"]["action"] == "spawn"

    def test_second_dataset_runner_delegate_refused(self):
        result = am.plan_delegate(
            "docking_owner",
            "flexaidds_redpair_20260726",
            agent_id="dataset_runner",
            monitor_connected=["dataset_runner"],
        )
        assert result["ok"] is False
        assert result["refused"] is True
        assert result["plan"] is None
        assert result["existing_heavy_owner"] == "dataset_runner"

    def test_find_existing_heavy_owner_ignores_analysts(self):
        assert (
            am.find_existing_heavy_owner(["science", "claude_code", "codex"]) is None
        )
        assert am.find_existing_heavy_owner(["dataset_runner"]) == "dataset_runner"


class TestCampaignCLI:
    def test_cli_campaign_dry_run_json(self, capsys):
        rc = am.main(
            [
                "campaign",
                "--campaign",
                "red-pair",
                "--task",
                "flexaidds_redpair_test",
                "--owner",
                "dataset_runner",
                "--analysts",
                "science",
                "--coders",
                "claude_code",
                "--dry-run",
                "--json",
            ]
        )
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["owner_agent_id"] == "dataset_runner"
        assert data["task_id"] == "flexaidds_redpair_test"
        assert data["ok"] is True
        assert "A" in data["phases"]

    def test_cli_campaign_refused_exit_3(self, capsys):
        rc = am.main(
            [
                "campaign",
                "--task",
                "flexaidds_redpair_test",
                "--connected",
                "dataset_runner",
                "--dry-run",
                "--json",
            ]
        )
        assert rc == 3
        data = json.loads(capsys.readouterr().out)
        assert data["refused"] is True
        assert data["ok"] is False

    def test_cli_delegate_dry_run(self, capsys):
        rc = am.main(
            [
                "delegate",
                "science",
                "--task",
                "flexaidds_redpair_test",
                "--dry-run",
                "--json",
            ]
        )
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["agent_id"] == "science"
        assert data["ok"] is True

    def test_cli_spawn_dry_run_still_works(self, capsys):
        rc = am.main(["spawn", "science", "--task", "t1", "--dry-run", "--json"])
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["agent_id"] == "science"
        assert data["task_id"] == "t1"
