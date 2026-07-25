"""Smoke the real `./scripts/shannon export` entry against a temp DB."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

import shannon_gate as sg

REPO = Path(__file__).resolve().parents[2]
SHANNON_SCRIPT = REPO / "scripts" / "shannon"


@pytest.mark.skipif(not SHANNON_SCRIPT.is_file(), reason="scripts/shannon missing")
def test_shannon_export_cli_entry(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Drive the shipped script's export path with HOME pointed at tmp.

    Uses the real write_jsonl call shape (out, db_path=db). A regression that
    swaps the args fails this test with TypeError or zero output.
    """
    home = tmp_path / "home"
    shannon = home / ".shannon"
    shannon.mkdir(parents=True)
    db_path = shannon / "agent_hub.db"
    db = sg.AuditDB(db_path)
    db.log_activity_event("science", "status", "export-cli", "ok")
    db.upsert_interaction("ask-export", "science", "Ship?", "pending")

    env = os.environ.copy()
    env["HOME"] = str(home)
    # Ensure python can import hub modules when the script runs.
    env["PYTHONPATH"] = str(REPO / "hub") + os.pathsep + env.get("PYTHONPATH", "")

    proc = subprocess.run(
        [str(SHANNON_SCRIPT), "export"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
        cwd=str(REPO),
    )
    assert proc.returncode == 0, (
        f"export failed rc={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
    )
    assert "wrote" in proc.stdout.lower() or "events" in proc.stdout.lower()
    out = shannon / "session_export.jsonl"
    assert out.is_file(), f"expected {out}; stdout={proc.stdout!r} stderr={proc.stderr!r}"
    body = out.read_text()
    assert body.strip(), "export file must be non-empty for a DB with events"
    assert "export-cli" in body or "science" in body
