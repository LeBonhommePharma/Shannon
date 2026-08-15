# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: Apache-2.0
"""Tests for the Ori-style `shannon <keyword>` agent harness."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest
from shannon.harness import (
    HARNESSES,
    HarnessUsageError,
    all_primary_keywords,
    execute_harness,
    format_cli_help,
    is_harness_keyword,
    missing_binary_message,
    parse_harness_invocation,
    peek_keyword,
    plan_launch,
    resolve_harness,
)

REPO = Path(__file__).resolve().parents[2]
SHANNON_SH = REPO / "scripts" / "shannon"

# Majority of common agent CLIs the harness is expected to launch.
# (keyword, binary, hub agent_id, display fragment)
COMMON_AGENT_CLIS: tuple[tuple[str, str, str, str], ...] = (
    ("claude", "claude", "claude_code", "Claude Code"),
    ("codex", "codex", "codex", "Codex"),
    ("grok", "grok", "grok_build", "Grok Build"),
    ("deepseek", "deepseek", "deepseek", "DeepSeek"),
    ("kimi", "kimi", "kimi", "Kimi"),
    ("opencode", "opencode", "opencode", "OpenCode"),
    ("cursor", "cursor", "cursor", "Cursor"),
)

COMMON_ALIASES: tuple[tuple[str, str, str], ...] = (
    ("cc", "claude", "claude_code"),
    ("claude_code", "claude", "claude_code"),
    ("openai_codex", "codex", "codex"),
    ("grok_build", "grok", "grok_build"),
    ("xai", "grok", "grok_build"),
    ("oc", "opencode", "opencode"),
    ("ds", "deepseek", "deepseek"),
    ("deepseek_tui", "deepseek", "deepseek"),
)


def _install_fake_agent(tmp_path: Path, name: str = "grok", exit_code: int = 0) -> Path:
    """Create a PATH directory with a fake agent CLI that echoes Shannon env."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    body = (
        "#!"
        + sys.executable
        + "\n"
        "import json, os, sys\n"
        f"sys.exit_code_override = {exit_code}\n"
        "print(json.dumps({\n"
        "    'argv': sys.argv[1:],\n"
        "    'env': {k: os.environ[k] for k in sorted(os.environ) if k.startswith('SHANNON_')},\n"
        "}), flush=True)\n"
        f"raise SystemExit({exit_code})\n"
    )
    if os.name == "nt":
        py = bindir / f"_{name}.py"
        py.write_text(body, encoding="utf-8")
        bat = bindir / f"{name}.bat"
        bat.write_text(f'@echo off\n"{sys.executable}" "{py}" %*\n', encoding="utf-8")
    else:
        target = bindir / name
        target.write_text(body, encoding="utf-8")
        target.chmod(target.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return bindir


class TestCatalog:
    def test_primary_keywords_include_codex_and_grok(self):
        keys = all_primary_keywords()
        assert "codex" in keys
        assert "grok" in keys
        assert "claude" in keys

    def test_aliases_resolve_to_canonical_hub_ids(self):
        assert resolve_harness("grok").agent_id == "grok_build"
        assert resolve_harness("GROK_BUILD").agent_id == "grok_build"
        assert resolve_harness("cc").agent_id == "claude_code"
        assert resolve_harness("claude").binary == "claude"
        assert resolve_harness("openai_codex").keyword == "codex"

    def test_unknown_keyword_is_not_a_harness(self):
        assert resolve_harness("not-an-agent") is None
        assert not is_harness_keyword("stdin")
        assert not is_harness_keyword("status")
        assert is_harness_keyword("grok")


class TestCommonAgentCLIs:
    """Round-trip the common agent CLIs (Claude Code, Codex, Grok Build, …)."""

    @pytest.mark.parametrize(
        "keyword,binary,agent_id,display",
        COMMON_AGENT_CLIS,
        ids=[row[0] for row in COMMON_AGENT_CLIS],
    )
    def test_catalog_maps_keyword_binary_and_hub_id(
        self, keyword: str, binary: str, agent_id: str, display: str
    ):
        spec = resolve_harness(keyword)
        assert spec is not None
        assert spec.keyword == keyword
        assert spec.binary == binary
        assert spec.agent_id == agent_id
        assert display in spec.display_name
        assert is_harness_keyword(keyword)
        assert keyword in all_primary_keywords()

    @pytest.mark.parametrize(
        "alias,keyword,agent_id",
        COMMON_ALIASES,
        ids=[row[0] for row in COMMON_ALIASES],
    )
    def test_aliases_resolve(self, alias: str, keyword: str, agent_id: str):
        spec = resolve_harness(alias)
        assert spec is not None
        assert spec.keyword == keyword
        assert spec.agent_id == agent_id

    @pytest.mark.parametrize("keyword", [row[0] for row in COMMON_AGENT_CLIS])
    def test_peek_and_parse_passthrough(self, keyword: str):
        assert peek_keyword(["--dry-run", "--json", keyword, "--model", "x"]) == keyword
        inv = parse_harness_invocation(
            [keyword, "--task", f"t-{keyword}", "--model", "x", "-p", "hi"]
        )
        assert inv.keyword == keyword
        assert inv.options.task_id == f"t-{keyword}"
        assert inv.agent_argv == ("--model", "x", "-p", "hi")

    @pytest.mark.parametrize(
        "keyword,binary,agent_id,display",
        COMMON_AGENT_CLIS,
        ids=[row[0] for row in COMMON_AGENT_CLIS],
    )
    def test_missing_binary_is_honest(
        self, tmp_path: Path, keyword: str, binary: str, agent_id: str, display: str
    ):
        empty = tmp_path / "empty"
        empty.mkdir()
        plan = plan_launch(keyword, path=str(empty), gate_socket_exists=False)
        assert plan.binary_found is False
        assert plan.agent_id == agent_id
        assert plan.binary == binary
        assert plan.argv == (binary,)
        msg = missing_binary_message(plan)
        assert f"`{binary}`" in msg
        assert display in msg
        assert f"shannon {keyword}" in msg

    @pytest.mark.parametrize(
        "keyword,binary,agent_id,_display",
        COMMON_AGENT_CLIS,
        ids=[row[0] for row in COMMON_AGENT_CLIS],
    )
    def test_found_binary_env_and_passthrough(
        self, tmp_path: Path, keyword: str, binary: str, agent_id: str, _display: str
    ):
        bindir = _install_fake_agent(tmp_path, binary)
        plan = plan_launch(
            keyword,
            ["--full-auto", "--model", "x"],
            path=str(bindir),
            task_id=f"task-{keyword}",
            gate_socket_exists=True,
        )
        assert plan.binary_found is True
        assert plan.binary_path is not None
        assert plan.argv[0] == plan.binary_path
        assert plan.argv[1:] == ("--full-auto", "--model", "x")
        assert plan.extra_env["SHANNON_HARNESS"] == "1"
        assert plan.extra_env["SHANNON_AGENT_ID"] == agent_id
        assert plan.extra_env["SHANNON_HARNESS_KEYWORD"] == keyword
        assert plan.extra_env["SHANNON_TASK_ID"] == f"task-{keyword}"
        assert plan.gate_status == "attach"

    @pytest.mark.parametrize(
        "keyword,binary,agent_id,_display",
        COMMON_AGENT_CLIS,
        ids=[row[0] for row in COMMON_AGENT_CLIS],
    )
    def test_dry_run_json(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
        keyword: str,
        binary: str,
        agent_id: str,
        _display: str,
    ):
        bindir = _install_fake_agent(tmp_path, binary)
        code = execute_harness(
            [keyword, "--dry-run", "--json", "--task", f"t-{keyword}", "-p", "hello"],
            path=str(bindir),
            gate_socket_exists=False,
        )
        assert code == 0
        payload = json.loads(capsys.readouterr().out)
        assert payload["keyword"] == keyword
        assert payload["agent_id"] == agent_id
        assert payload["binary"] == binary
        assert payload["binary_found"] is True
        assert payload["argv"][1:] == ["-p", "hello"]

    @pytest.mark.parametrize(
        "keyword,binary,agent_id,_display",
        COMMON_AGENT_CLIS,
        ids=[row[0] for row in COMMON_AGENT_CLIS],
    )
    def test_live_launch_injects_env(
        self,
        tmp_path: Path,
        capfd: pytest.CaptureFixture[str],
        keyword: str,
        binary: str,
        agent_id: str,
        _display: str,
    ):
        bindir = _install_fake_agent(tmp_path, binary)
        code = execute_harness(
            [keyword, "--no-gate", "--task", f"live-{keyword}", "--full-auto"],
            path=str(bindir),
            gate_socket_exists=False,
        )
        assert code == 0
        payload = json.loads(capfd.readouterr().out)
        assert payload["argv"] == ["--full-auto"]
        assert payload["env"]["SHANNON_HARNESS"] == "1"
        assert payload["env"]["SHANNON_AGENT_ID"] == agent_id
        assert payload["env"]["SHANNON_TASK_ID"] == f"live-{keyword}"
        assert payload["env"]["SHANNON_GATE_ATTACH"] == "skipped"

    @pytest.mark.parametrize(
        "keyword,binary,agent_id,_display",
        COMMON_AGENT_CLIS,
        ids=[row[0] for row in COMMON_AGENT_CLIS],
    )
    def test_cli_module_dry_run(
        self, tmp_path: Path, keyword: str, binary: str, agent_id: str, _display: str
    ):
        bindir = _install_fake_agent(tmp_path, binary)
        env = os.environ.copy()
        env["PYTHONPATH"] = str(REPO / "python")
        env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
        proc = subprocess.run(
            [
                sys.executable,
                "-m",
                "shannon.cli",
                keyword,
                "--dry-run",
                "--json",
                "--no-gate",
            ],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(REPO),
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        payload = json.loads(proc.stdout)
        assert payload["keyword"] == keyword
        assert payload["agent_id"] == agent_id
        assert payload["binary_found"] is True

    def test_help_lists_every_common_cli(self):
        text = format_cli_help("shannon")
        for keyword, _binary, _agent_id, display in COMMON_AGENT_CLIS:
            assert keyword in text, keyword
            assert display in text, display


class TestArgv:
    def test_peek_skips_leading_shannon_flags(self):
        assert peek_keyword(["--dry-run", "--json", "grok", "--full-auto"]) == "grok"
        assert peek_keyword(["grok"]) == "grok"
        assert peek_keyword(["--help"]) is None
        assert peek_keyword(["stdin"]) == "stdin"

    def test_parse_consumes_shannon_flags_then_passthrough(self):
        inv = parse_harness_invocation(
            ["--dry-run", "grok", "--task", "t1", "--full-auto", "-p", "hi"]
        )
        assert inv.keyword == "grok"
        assert inv.options.dry_run is True
        assert inv.options.task_id == "t1"
        assert inv.agent_argv == ("--full-auto", "-p", "hi")

    def test_double_dash_ends_shannon_flags(self):
        inv = parse_harness_invocation(["codex", "--", "--dry-run", "--json"])
        assert inv.keyword == "codex"
        assert inv.options.dry_run is False
        assert inv.agent_argv == ("--dry-run", "--json")

    def test_equals_form_and_no_gate(self):
        inv = parse_harness_invocation(
            ["claude", "--threshold=-1.5", "--window=4", "--no-gate"]
        )
        assert inv.options.threshold == -1.5
        assert inv.options.window == 4
        assert inv.options.attach_gate is False
        assert inv.agent_argv == ()

    def test_missing_keyword_raises(self):
        with pytest.raises(HarnessUsageError):
            parse_harness_invocation(["--dry-run"])


class TestPlan:
    def test_missing_binary_is_honest(self, tmp_path):
        empty = tmp_path / "empty"
        empty.mkdir()
        plan = plan_launch("grok", path=str(empty), task_id="t1", gate_socket_exists=False)
        assert plan.binary_found is False
        assert plan.agent_id == "grok_build"
        assert plan.argv == ("grok",)
        assert plan.gate_status == "offline"
        msg = missing_binary_message(plan)
        assert "`grok`" in msg
        assert "curl -fsSL https://x.ai/cli/install.sh" in msg
        assert "shannon grok" in msg

    def test_found_binary_and_env(self, tmp_path):
        bindir = _install_fake_agent(tmp_path, "codex")
        plan = plan_launch(
            "codex",
            ["--full-auto"],
            path=str(bindir),
            task_id="task-9",
            gate_socket_exists=True,
        )
        assert plan.binary_found is True
        assert plan.binary_path is not None
        assert plan.argv[0] == plan.binary_path
        assert plan.argv[1:] == ("--full-auto",)
        assert plan.extra_env["SHANNON_HARNESS"] == "1"
        assert plan.extra_env["SHANNON_AGENT_ID"] == "codex"
        assert plan.extra_env["SHANNON_TASK_ID"] == "task-9"
        assert plan.gate_status == "attach"
        assert any("No token-level entropy is claimed" in note for note in plan.notes)

    def test_no_gate_skips_attach(self, tmp_path):
        bindir = _install_fake_agent(tmp_path)
        plan = plan_launch(
            "grok", path=str(bindir), attach_gate=False, gate_socket_exists=True
        )
        assert plan.gate_status == "skipped"

    def test_unknown_keyword_raises(self):
        with pytest.raises(HarnessUsageError, match="unknown agent"):
            plan_launch("definitely-not")


class TestExecute:
    def test_dry_run_json_when_found(self, tmp_path, capsys):
        bindir = _install_fake_agent(tmp_path, "grok")
        code = execute_harness(
            ["grok", "--dry-run", "--json", "--task", "t1", "-p", "hello"],
            path=str(bindir),
            gate_socket_exists=False,
        )
        assert code == 0
        payload = json.loads(capsys.readouterr().out)
        assert payload["agent_id"] == "grok_build"
        assert payload["binary_found"] is True
        assert payload["argv"][1:] == ["-p", "hello"]
        assert payload["binary"] == "grok"
        assert payload["gate_status"] == "offline"

    def test_dry_run_missing_binary_exits_1(self, tmp_path, capsys):
        empty = tmp_path / "empty"
        empty.mkdir()
        code = execute_harness(
            ["claude", "--dry-run"],
            path=str(empty),
            gate_socket_exists=False,
        )
        assert code == 1
        captured = capsys.readouterr()
        assert "could not find" in captured.err
        assert "claude" in captured.out.lower() or "Claude" in captured.out

    def test_unknown_keyword_exits_2(self, capsys):
        code = execute_harness(["nope-bot", "--dry-run"])
        assert code == 2
        assert "unknown agent" in capsys.readouterr().err

    def test_launch_runs_real_argv_and_injects_env(self, tmp_path, capfd):
        bindir = _install_fake_agent(tmp_path, "grok")
        code = execute_harness(
            ["grok", "--no-gate", "--task", "live1", "--full-auto"],
            path=str(bindir),
            gate_socket_exists=False,
        )
        assert code == 0
        payload = json.loads(capfd.readouterr().out)
        assert payload["argv"] == ["--full-auto"]
        assert payload["env"]["SHANNON_HARNESS"] == "1"
        assert payload["env"]["SHANNON_AGENT_ID"] == "grok_build"
        assert payload["env"]["SHANNON_TASK_ID"] == "live1"
        assert payload["env"]["SHANNON_GATE_ATTACH"] == "skipped"

    def test_agent_exit_code_is_preserved(self, tmp_path):
        bindir = _install_fake_agent(tmp_path, "codex", exit_code=7)
        code = execute_harness(
            ["codex", "--no-gate"],
            path=str(bindir),
            gate_socket_exists=False,
        )
        assert code == 7


class TestCliMain:
    def test_help_lists_harness_and_shannon_cli(self):
        proc = subprocess.run(
            [sys.executable, "-m", "shannon.cli", "--help"],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(REPO),
            env={**os.environ, "PYTHONPATH": str(REPO / "python")},
        )
        assert proc.returncode == 0
        out = proc.stdout + proc.stderr
        assert "Shannon CLI" in out
        assert "grok" in out
        assert "codex" in out
        assert "claude" in out
        assert "deepseek" in out
        assert "kimi" in out
        assert "opencode" in out
        assert "cursor" in out

    def test_main_grok_dry_run_via_module(self, tmp_path):
        bindir = _install_fake_agent(tmp_path, "grok")
        env = os.environ.copy()
        env["PYTHONPATH"] = str(REPO / "python")
        env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
        proc = subprocess.run(
            [sys.executable, "-m", "shannon.cli", "grok", "--dry-run", "--json", "--no-gate"],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(REPO),
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        payload = json.loads(proc.stdout)
        assert payload["keyword"] == "grok"
        assert payload["binary_found"] is True

    def test_module_shannon_entrypoint(self):
        proc = subprocess.run(
            [sys.executable, "-m", "shannon", "--help"],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(REPO),
            env={**os.environ, "PYTHONPATH": str(REPO / "python")},
        )
        assert proc.returncode == 0
        assert "Shannon CLI" in (proc.stdout + proc.stderr)

    def test_help_text_builder_mentions_ori_instinct(self):
        text = format_cli_help("shannon")
        assert "shannon grok" in text
        assert "passed through untouched" in text


class TestOperatorScript:
    def test_case_arm_lists_every_catalog_keyword(self):
        src = SHANNON_SH.read_text(encoding="utf-8")
        for spec in HARNESSES:
            assert spec.keyword in src, spec.keyword
            for alias in spec.aliases:
                assert alias in src, alias

    @pytest.mark.skipif(sys.platform == "win32", reason="bash operator script")
    def test_scripts_shannon_grok_dry_run(self, tmp_path):
        bindir = _install_fake_agent(tmp_path, "grok")
        env = os.environ.copy()
        env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
        proc = subprocess.run(
            ["bash", str(SHANNON_SH), "grok", "--dry-run", "--json", "--no-gate"],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(REPO),
            env=env,
        )
        assert proc.returncode == 0, proc.stdout + proc.stderr
        payload = json.loads(proc.stdout)
        assert payload["agent_id"] == "grok_build"
        assert payload["binary_found"] is True

    @pytest.mark.skipif(sys.platform == "win32", reason="bash operator script")
    @pytest.mark.parametrize(
        "keyword,binary,agent_id,_display",
        COMMON_AGENT_CLIS,
        ids=[row[0] for row in COMMON_AGENT_CLIS],
    )
    def test_scripts_shannon_common_cli_dry_run(
        self, tmp_path: Path, keyword: str, binary: str, agent_id: str, _display: str
    ):
        bindir = _install_fake_agent(tmp_path, binary)
        env = os.environ.copy()
        env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
        proc = subprocess.run(
            ["bash", str(SHANNON_SH), keyword, "--dry-run", "--json", "--no-gate"],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(REPO),
            env=env,
        )
        assert proc.returncode == 0, proc.stdout + proc.stderr
        payload = json.loads(proc.stdout)
        assert payload["keyword"] == keyword
        assert payload["agent_id"] == agent_id
        assert payload["binary_found"] is True

    @pytest.mark.skipif(sys.platform == "win32", reason="bash operator script")
    def test_scripts_shannon_help_mentions_harness(self):
        proc = subprocess.run(
            ["bash", str(SHANNON_SH), "help"],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(REPO),
        )
        assert proc.returncode == 0
        out = proc.stdout
        assert "shannon grok" in out
        assert "Ori-style" in out
