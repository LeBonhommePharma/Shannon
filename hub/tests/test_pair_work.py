"""Shannon-owned Claude Code ↔ Codex pair / cross-review plans (pure, no gate)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import agent_manager as am


class TestPairImplement:
    def test_implement_pair_half_and_half(self):
        plan = am.plan_pair_work(
            "implement_pair",
            task_id="pair_auth_20260726",
            summary="Auth middleware + tests",
        )
        d = plan.as_dict()
        assert d["ok"] is True
        assert d["refused"] is False
        assert d["action"] == "pair"
        assert d["mode"] == "implement_pair"
        assert d["task_id"] == "pair_auth_20260726"
        assert set(d["agents"]) == {"claude_code", "codex"}
        assert d["fabricated_review"] is None
        assert d["fabricated_code"] is None
        impl = [a for a in d["assignments"] if a["role"] == "implement"]
        assert len(impl) == 2
        slices = {a["slice"] for a in impl}
        assert slices == {"slice_a", "slice_b"}
        by_agent = {a["agent_id"]: a for a in impl}
        assert by_agent["claude_code"]["implements_with"] == "codex"
        assert by_agent["codex"]["implements_with"] == "claude_code"
        for a in impl:
            assert a["plan"]["action"] == "spawn"
            assert a["plan"]["task_id"] == "pair_auth_20260726"
            assert a["plan"]["payload"].get("pair_work") is True


class TestCrossReview:
    def test_mutual_cross_review(self):
        plan = am.plan_pair_work("cross_review", task_id="pair_xr_1", summary="Feature X")
        d = plan.as_dict()
        assert d["ok"] is True
        assert set(d["agents"]) == {"claude_code", "codex"}
        impl = [a for a in d["assignments"] if a["role"] == "implement"]
        rev = [a for a in d["assignments"] if a["role"] == "review"]
        assert len(impl) == 2
        assert len(rev) == 2
        # Claude reviews Codex's slice_b; Codex reviews Claude's slice_a
        claude_rev = next(a for a in rev if a["agent_id"] == "claude_code")
        codex_rev = next(a for a in rev if a["agent_id"] == "codex")
        assert claude_rev["reviews_agent"] == "codex"
        assert claude_rev["slice"] == "slice_b"
        assert codex_rev["reviews_agent"] == "claude_code"
        assert codex_rev["slice"] == "slice_a"

    def test_claude_implements_codex_reviews(self):
        plan = am.plan_pair_work(
            "claude_implements", task_id="pair_ci_1", summary="Implement feature"
        )
        d = plan.as_dict()
        impl = [a for a in d["assignments"] if a["role"] == "implement"]
        rev = [a for a in d["assignments"] if a["role"] == "review"]
        assert len(impl) == 1 and impl[0]["agent_id"] == "claude_code"
        assert impl[0]["slice"] == "full"
        assert len(rev) == 1 and rev[0]["agent_id"] == "codex"
        assert rev[0]["reviews_agent"] == "claude_code"

    def test_codex_implements_claude_reviews(self):
        plan = am.plan_pair_work(
            "codex_implements", task_id="pair_xi_1", summary="Implement feature"
        )
        d = plan.as_dict()
        impl = [a for a in d["assignments"] if a["role"] == "implement"]
        rev = [a for a in d["assignments"] if a["role"] == "review"]
        assert impl[0]["agent_id"] == "codex"
        assert rev[0]["agent_id"] == "claude_code"
        assert rev[0]["reviews_agent"] == "codex"


class TestPairRefuse:
    def test_unknown_mode_refused(self):
        plan = am.plan_pair_work("nope_mode", task_id="t1")
        assert plan.refused is True
        assert plan.as_dict()["ok"] is False
        assert plan.assignments == ()

    def test_pair_requires_two_distinct_agents(self):
        plan = am.plan_pair_work(
            "implement_pair",
            task_id="t1",
            agent_a="claude_code",
            agent_b="claude_code",
        )
        assert plan.refused is True
        assert "distinct" in plan.refuse_reason.lower()

    def test_implement_only_allows_single_agent(self):
        plan = am.plan_pair_work(
            "implement_only",
            task_id="solo_1",
            agent_a="claude_code",
            agent_b="claude_code",
        )
        d = plan.as_dict()
        assert d["ok"] is True
        assert len(d["assignments"]) == 1
        assert d["assignments"][0]["agent_id"] == "claude_code"
        assert d["assignments"][0]["role"] == "implement"

    def test_unknown_agent_slug_still_normalizes(self):
        # Unknown slug passthrough is allowed; pair still needs two distinct ids.
        plan = am.plan_pair_work(
            "implement_pair",
            task_id="t1",
            agent_a="claude_code",
            agent_b="my_custom_bot",
        )
        assert plan.refused is False
        assert set(plan.as_dict()["agents"]) == {"claude_code", "my_custom_bot"}


class TestPairCLI:
    def test_cli_pair_implement_dry_run(self, capsys):
        rc = am.main(
            [
                "pair",
                "--pair-mode",
                "implement_pair",
                "--task",
                "pair_cli_1",
                "--summary",
                "Half and half auth",
                "--dry-run",
                "--json",
            ]
        )
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["mode"] == "implement_pair"
        assert set(data["agents"]) == {"claude_code", "codex"}
        assert data["task_id"] == "pair_cli_1"
        assert data["ok"] is True

    def test_cli_pair_cross_review_dry_run(self, capsys):
        rc = am.main(
            [
                "pair",
                "--pair-mode",
                "cross_review",
                "--task",
                "pair_cli_xr",
                "--dry-run",
                "--json",
            ]
        )
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        roles = {a["role"] for a in data["assignments"]}
        assert roles == {"implement", "review"}

    def test_cli_pair_refused_exit_3(self, capsys):
        rc = am.main(
            [
                "pair",
                "--pair-mode",
                "implement_pair",
                "--agent-a",
                "codex",
                "--agent-b",
                "codex",
                "--dry-run",
                "--json",
            ]
        )
        assert rc == 3
        data = json.loads(capsys.readouterr().out)
        assert data["refused"] is True
