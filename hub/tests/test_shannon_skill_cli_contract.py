"""Contract: Shannon skill documents the real agent_manager bootstrap path.

Regression for: SKILL.md must never route lifecycle through
``./scripts/shannon hub …`` (that alias runs bootstrap_all and drops args).
Lifecycle is ``./scripts/shannon agent …`` → ``python3 -m agent_manager``.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SKILL_MD = REPO / "skills" / "shannon" / "SKILL.md"
SHANNON_SH = REPO / "scripts" / "shannon"
HUB = REPO / "hub"

# Forbidden: bootstrap_all alias used as if it were the agent manager.
_FORBIDDEN_BOOTSTRAP_AS_LIFECYCLE = re.compile(
    r"^\s*\./scripts/shannon\s+hub\s+(roster|spawn|monitor|kill|control|ask|result)\b",
    re.MULTILINE,
)

# Required: documented agent subcommand for lifecycle.
_REQUIRED_AGENT_CLI = re.compile(
    r"^\s*\./scripts/shannon\s+agent\s+(roster|spawn|monitor|kill|control)\b",
    re.MULTILINE,
)


class TestSkillMdCliContract:
    def test_skill_md_exists(self):
        assert SKILL_MD.is_file()

    def test_skill_md_does_not_document_hub_as_lifecycle(self):
        text = SKILL_MD.read_text(encoding="utf-8")
        bad = _FORBIDDEN_BOOTSTRAP_AS_LIFECYCLE.findall(text)
        assert not bad, (
            "SKILL.md must not document `./scripts/shannon hub <lifecycle>` — "
            f"`hub` is bootstrap_all. Found: {bad}"
        )
        # Also ban the exact broken block the skeptic found.
        assert "./scripts/shannon hub roster" not in text
        assert "./scripts/shannon hub spawn" not in text
        assert "./scripts/shannon hub monitor" not in text

    def test_skill_md_documents_agent_lifecycle_cli(self):
        text = SKILL_MD.read_text(encoding="utf-8")
        found = _REQUIRED_AGENT_CLI.findall(text)
        for verb in ("roster", "spawn", "monitor", "kill", "control"):
            assert verb in found, (
                f"SKILL.md must document `./scripts/shannon agent {verb}` "
                f"(found verbs: {found})"
            )

    def test_scripts_shannon_wires_agent_to_agent_manager(self):
        src = SHANNON_SH.read_text(encoding="utf-8")
        # Case arm for agent aliases
        assert re.search(
            r"agent\|agents\|hub-agent\)",
            src,
        ), "scripts/shannon must accept agent|agents|hub-agent"
        assert "python3 -m agent_manager" in src
        # And hub remains bootstrap, not lifecycle
        assert re.search(r"bootstrap\|hub\|up\|", src) or re.search(
            r'bootstrap\|hub\|up\|""\)',
            src,
        )


class TestScriptsShannonAgentDryRun:
    """Drive the real bootstrap path: scripts/shannon agent → agent_manager."""

    def _run_agent(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SHANNON_SH), "agent", *args],
            cwd=str(REPO),
            capture_output=True,
            text=True,
            timeout=30,
            env={
                **dict(__import__("os").environ),
                "PYTHONPATH": str(HUB)
                + (
                    (":" + __import__("os").environ["PYTHONPATH"])
                    if __import__("os").environ.get("PYTHONPATH")
                    else ""
                ),
            },
        )

    def test_agent_roster_json(self):
        proc = self._run_agent("roster", "--json")
        assert proc.returncode == 0, proc.stderr + proc.stdout
        data = json.loads(proc.stdout)
        assert data.get("ok") is True
        ids = {r["id"] for r in data["handrail"]}
        for aid in (
            "grok_build",
            "codex",
            "claude_code",
            "science",
            "cowork",
            "dispatch",
            "design",
            "opencode",
        ):
            assert aid in ids

    def test_agent_spawn_dry_run(self):
        proc = self._run_agent(
            "spawn", "science", "--task", "contract_t1", "--dry-run", "--json"
        )
        assert proc.returncode == 0, proc.stderr + proc.stdout
        data = json.loads(proc.stdout)
        assert data["action"] == "spawn"
        assert data["agent_id"] == "science"
        assert data["task_id"] == "contract_t1"

    def test_agent_monitor_dry_run(self):
        proc = self._run_agent("monitor", "--dry-run", "--json")
        assert proc.returncode == 0, proc.stderr + proc.stdout
        data = json.loads(proc.stdout)
        assert data["action"] == "monitor"

    def test_agent_kill_dry_run(self):
        proc = self._run_agent(
            "kill", "codex", "--task", "contract_t1", "--dry-run", "--json"
        )
        assert proc.returncode == 0, proc.stderr + proc.stdout
        data = json.loads(proc.stdout)
        assert data["action"] == "kill"
        assert data["agent_id"] == "codex"

    def test_agent_control_dry_run(self):
        proc = self._run_agent(
            "control",
            "dispatch",
            "heartbeat",
            "--task",
            "contract_t1",
            "--dry-run",
            "--json",
        )
        assert proc.returncode == 0, proc.stderr + proc.stdout
        data = json.loads(proc.stdout)
        assert data["action"] == "control"
        assert data["payload"]["message"] == "heartbeat"
