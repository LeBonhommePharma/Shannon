# =============================================================================
# Shannon agent harness — Ori-style `shannon <keyword>` launcher
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================
"""Launch the real agent CLI already on PATH, tagged for Shannon.

Mirrors Ori Harness (``ori claude`` / ``ori codex``): the first argument is
the agent keyword, Shannon finds that CLI on ``PATH``, and every remaining
argument is passed through untouched. Shannon does not replace the agent and
does not invent token-level entropy for CLIs that do not expose logprobs.

Optional hub attach is fail-open: a missing gate never blocks the launch.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from collections.abc import Mapping, Sequence
from dataclasses import asdict, dataclass, field

# Hub is part of the clone, not the PyPI extra. Absence is the normal pip path.
try:
    import agent_manager as _agent_manager  # type: ignore[import-not-found]
except ImportError:
    _agent_manager = None

DEFAULT_GATE_SOCKET = "/tmp/shannon.sock"
DEFAULT_THRESHOLD = -3.2
DEFAULT_WINDOW = 8

# Monitor subcommands that must keep beating the harness keyword lookup.
MONITOR_COMMANDS = frozenset({"stdin", "openai", "info"})


class HarnessUsageError(ValueError):
    """User-facing argv error (missing flag value, empty keyword)."""


@dataclass(frozen=True, slots=True)
class AgentHarness:
    keyword: str
    binary: str
    agent_id: str
    display_name: str
    install_hint: str
    docs_url: str
    aliases: tuple[str, ...] = ()


# Primary keywords match Ori's instinct (`ori <cli>`) plus Shannon roster CLIs.
HARNESSES: tuple[AgentHarness, ...] = (
    AgentHarness(
        keyword="claude",
        aliases=("claude_code", "cc", "claudecode"),
        binary="claude",
        agent_id="claude_code",
        display_name="Claude Code",
        install_hint="npm install -g @anthropic-ai/claude-code",
        docs_url="https://docs.anthropic.com/en/docs/claude-code",
    ),
    AgentHarness(
        keyword="codex",
        aliases=("openai_codex",),
        binary="codex",
        agent_id="codex",
        display_name="Codex",
        install_hint="npm install -g @openai/codex",
        docs_url="https://github.com/openai/codex",
    ),
    AgentHarness(
        keyword="grok",
        aliases=("grok_build", "xai", "grokbuild"),
        binary="grok",
        agent_id="grok_build",
        display_name="Grok Build",
        install_hint="curl -fsSL https://x.ai/cli/install.sh | bash",
        docs_url="https://docs.x.ai/build/overview",
    ),
    AgentHarness(
        keyword="opencode",
        aliases=("open_code", "oc"),
        binary="opencode",
        agent_id="opencode",
        display_name="OpenCode",
        install_hint="curl -fsSL https://opencode.ai/install | bash",
        docs_url="https://opencode.ai",
    ),
    AgentHarness(
        keyword="kimi",
        aliases=(),
        binary="kimi",
        agent_id="kimi",
        display_name="Kimi",
        install_hint="Install the Kimi CLI so `kimi` is on PATH.",
        docs_url="https://www.kimi.com",
    ),
    AgentHarness(
        keyword="hermes",
        aliases=(),
        binary="hermes",
        agent_id="hermes",
        display_name="Hermes",
        install_hint="Install the Hermes agent CLI so `hermes` is on PATH.",
        docs_url="https://openrouter.ai/docs/guides/ori/harness",
    ),
    AgentHarness(
        keyword="pi",
        aliases=(),
        binary="pi",
        agent_id="pi",
        display_name="Pi",
        install_hint="curl -fsSL https://pi.dev/install.sh | sh",
        docs_url="https://pi.dev",
    ),
    AgentHarness(
        keyword="cursor",
        aliases=(),
        binary="cursor",
        agent_id="cursor",
        display_name="Cursor",
        install_hint="Install Cursor; the `cursor` CLI ships with the app.",
        docs_url="https://cursor.com",
    ),
    AgentHarness(
        keyword="prime-agent",
        aliases=("prime_agent", "primeagent"),
        binary="prime-agent",
        agent_id="prime_agent",
        display_name="Prime Agent",
        install_hint="curl -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh",
        docs_url="https://openrouter.ai/docs/guides/ori/harness",
    ),
)


def _index_harnesses() -> dict[str, AgentHarness]:
    out: dict[str, AgentHarness] = {}
    for spec in HARNESSES:
        out[spec.keyword] = spec
        for alias in spec.aliases:
            out[alias] = spec
    return out


_HARNESS_BY_KEYWORD = _index_harnesses()


def all_primary_keywords() -> tuple[str, ...]:
    return tuple(spec.keyword for spec in HARNESSES)


def is_harness_keyword(raw: str) -> bool:
    key = _normalize_keyword(raw)
    return bool(key) and key in _HARNESS_BY_KEYWORD


def resolve_harness(raw: str) -> AgentHarness | None:
    key = _normalize_keyword(raw)
    if not key:
        return None
    return _HARNESS_BY_KEYWORD.get(key)


def _normalize_keyword(raw: str) -> str:
    return (raw or "").strip().lower().replace(" ", "_")


@dataclass(frozen=True, slots=True)
class HarnessOptions:
    dry_run: bool = False
    json_out: bool = False
    attach_gate: bool = True
    task_id: str | None = None
    gate_socket: str = DEFAULT_GATE_SOCKET
    threshold: float = DEFAULT_THRESHOLD
    window: int = DEFAULT_WINDOW


@dataclass(frozen=True, slots=True)
class HarnessInvocation:
    options: HarnessOptions
    keyword: str
    agent_argv: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class LaunchPlan:
    keyword: str
    agent_id: str
    display_name: str
    binary: str
    binary_path: str | None
    argv: tuple[str, ...]
    extra_env: dict[str, str]
    task_id: str
    attach_gate: bool
    gate_status: str
    binary_found: bool
    install_hint: str
    docs_url: str
    threshold: float
    window: int
    notes: tuple[str, ...] = field(default_factory=tuple)

    def as_dict(self) -> dict[str, object]:
        data = asdict(self)
        data["argv"] = list(self.argv)
        data["notes"] = list(self.notes)
        return data


_BOOL_FLAGS = {
    "--dry-run": "dry_run",
    "--json": "json_out",
}
_VALUE_FLAGS = {
    "--task": "task_id",
    "--gate-socket": "gate_socket",
    "--threshold": "threshold",
    "--window": "window",
}


def default_task_id(agent_id: str, *, now: int | None = None, nonce: str | None = None) -> str:
    ts = int(now if now is not None else time.time())
    token = nonce if nonce is not None else uuid.uuid4().hex[:8]
    return f"harness_{agent_id}_{ts}_{token}"


def peek_keyword(argv: Sequence[str]) -> str | None:
    """First positional after leading Shannon flags, or None."""
    i = 0
    n = len(argv)
    while i < n:
        token = argv[i]
        if token == "--":
            return argv[i + 1] if i + 1 < n else None
        consumed = _flag_span(argv, i)
        if consumed:
            i += consumed
            continue
        if token.startswith("-"):
            return None
        return token
    return None


def parse_harness_invocation(argv: Sequence[str]) -> HarnessInvocation:
    """Split ``shannon [flags] <keyword> [flags] [agent argv…]``."""
    opts_dict: dict[str, object] = {
        "dry_run": False,
        "json_out": False,
        "attach_gate": True,
        "task_id": None,
        "gate_socket": DEFAULT_GATE_SOCKET,
        "threshold": DEFAULT_THRESHOLD,
        "window": DEFAULT_WINDOW,
    }
    i = 0
    n = len(argv)

    def apply_leading() -> None:
        nonlocal i
        while i < n:
            if argv[i] == "--":
                break
            consumed = _apply_flag(argv, i, opts_dict)
            if consumed is None:
                break
            i += consumed

    apply_leading()
    if i >= n:
        raise HarnessUsageError("missing agent keyword (try: shannon grok)")
    if argv[i] == "--":
        i += 1
        if i >= n:
            raise HarnessUsageError("missing agent keyword after --")
    keyword = argv[i]
    i += 1
    apply_leading()
    if i < n and argv[i] == "--":
        agent_argv = tuple(argv[i + 1 :])
    else:
        agent_argv = tuple(argv[i:])
    threshold_raw = opts_dict["threshold"]
    window_raw = opts_dict["window"]
    if not isinstance(threshold_raw, (int, float)):
        raise HarnessUsageError(f"--threshold has invalid value {threshold_raw!r}")
    if not isinstance(window_raw, int) or isinstance(window_raw, bool):
        raise HarnessUsageError(f"--window has invalid value {window_raw!r}")
    task_raw = opts_dict["task_id"]
    options = HarnessOptions(
        dry_run=bool(opts_dict["dry_run"]),
        json_out=bool(opts_dict["json_out"]),
        attach_gate=bool(opts_dict["attach_gate"]),
        task_id=task_raw if isinstance(task_raw, str) else None,
        gate_socket=str(opts_dict["gate_socket"]),
        threshold=float(threshold_raw),
        window=window_raw,
    )
    return HarnessInvocation(options=options, keyword=keyword, agent_argv=agent_argv)


def _flag_span(argv: Sequence[str], i: int) -> int:
    """How many tokens a Shannon flag occupies at i, else 0."""
    token = argv[i]
    if token in _BOOL_FLAGS or token == "--no-gate":
        return 1
    if token in _VALUE_FLAGS:
        return 2 if i + 1 < len(argv) else 1
    if token.startswith("--") and "=" in token:
        key = token.split("=", 1)[0]
        if key in _VALUE_FLAGS:
            return 1
    return 0


def _apply_flag(argv: Sequence[str], i: int, opts: dict[str, object]) -> int | None:
    token = argv[i]
    if token == "--no-gate":
        opts["attach_gate"] = False
        return 1
    if token in _BOOL_FLAGS:
        opts[_BOOL_FLAGS[token]] = True
        return 1
    if token in _VALUE_FLAGS:
        if i + 1 >= len(argv):
            raise HarnessUsageError(f"{token} requires a value")
        _store_value(opts, _VALUE_FLAGS[token], argv[i + 1], token)
        return 2
    if token.startswith("--") and "=" in token:
        key, _, raw = token.partition("=")
        if key in _VALUE_FLAGS:
            _store_value(opts, _VALUE_FLAGS[key], raw, key)
            return 1
    return None


def _store_value(opts: dict[str, object], field_name: str, raw: str, flag: str) -> None:
    if field_name == "threshold":
        try:
            opts[field_name] = float(raw)
        except ValueError as exc:
            raise HarnessUsageError(f"{flag} expects a float, got {raw!r}") from exc
        return
    if field_name == "window":
        try:
            opts[field_name] = int(raw)
        except ValueError as exc:
            raise HarnessUsageError(f"{flag} expects an int, got {raw!r}") from exc
        return
    opts[field_name] = raw


def plan_launch(
    keyword: str,
    agent_argv: Sequence[str] = (),
    *,
    path: str | None = None,
    task_id: str | None = None,
    attach_gate: bool = True,
    gate_socket: str = DEFAULT_GATE_SOCKET,
    threshold: float = DEFAULT_THRESHOLD,
    window: int = DEFAULT_WINDOW,
    gate_socket_exists: bool | None = None,
) -> LaunchPlan:
    spec = resolve_harness(keyword)
    if spec is None:
        known = ", ".join(all_primary_keywords())
        raise HarnessUsageError(
            f"unknown agent {keyword!r}. Known: {known}"
        )
    binary_path = shutil.which(spec.binary, path=path) if path is not None else shutil.which(
        spec.binary
    )
    tid = task_id or default_task_id(spec.agent_id)
    if not attach_gate:
        gate_status = "skipped"
    else:
        present = (
            os.path.exists(gate_socket)
            if gate_socket_exists is None
            else gate_socket_exists
        )
        gate_status = "attach" if present else "offline"
    extra_env = {
        "SHANNON_HARNESS": "1",
        "SHANNON_AGENT_ID": spec.agent_id,
        "SHANNON_HARNESS_KEYWORD": spec.keyword,
        "SHANNON_TASK_ID": tid,
        "SHANNON_THRESHOLD": f"{threshold}",
        "SHANNON_WINDOW": str(int(window)),
        "SHANNON_GATE_SOCKET": gate_socket,
    }
    argv = ((binary_path or spec.binary), *tuple(agent_argv))
    notes = (
        "Shannon launches the real CLI on PATH; remaining argv is passed through.",
        "No token-level entropy is claimed unless the agent exposes logprobs.",
        "Gate attach is fail-open and never required to start the agent.",
    )
    return LaunchPlan(
        keyword=spec.keyword,
        agent_id=spec.agent_id,
        display_name=spec.display_name,
        binary=spec.binary,
        binary_path=binary_path,
        argv=argv,
        extra_env=extra_env,
        task_id=tid,
        attach_gate=attach_gate,
        gate_status=gate_status,
        binary_found=binary_path is not None,
        install_hint=spec.install_hint,
        docs_url=spec.docs_url,
        threshold=float(threshold),
        window=int(window),
        notes=notes,
    )


def missing_binary_message(plan: LaunchPlan) -> str:
    return (
        f"Shannon could not find `{plan.binary}` on PATH.\n"
        f"\n"
        f"{plan.display_name} is the real CLI Shannon launches — install it, then rerun.\n"
        f"\n"
        f"  {plan.install_hint}\n"
        f"\n"
        f"Docs: {plan.docs_url}\n"
        f"\n"
        f"Then: shannon {plan.keyword}\n"
    )


def format_launch_plan_text(plan: LaunchPlan) -> str:
    found = "yes" if plan.binary_found else "no"
    path = plan.binary_path or "(not on PATH)"
    argv = " ".join(plan.argv)
    return (
        f"Shannon harness: {plan.display_name} ({plan.keyword})\n"
        f"  agent_id:     {plan.agent_id}\n"
        f"  binary:       {plan.binary}  found={found}\n"
        f"  path:         {path}\n"
        f"  argv:         {argv}\n"
        f"  task_id:      {plan.task_id}\n"
        f"  gate:         {plan.gate_status}  ({plan.extra_env['SHANNON_GATE_SOCKET']})\n"
        f"  threshold:    {plan.threshold} bits   window={plan.window}\n"
    )


def format_cli_help(prog: str) -> str:
    rows = "\n".join(
        f"  {spec.keyword:<14} {spec.display_name} (`{spec.binary}`)"
        for spec in HARNESSES
    )
    return (
        f"{prog} — Shannon CLI (headless; no GUI)\n"
        "\n"
        "Harness an agent the way Ori harnesses OpenRouter: first argument is\n"
        "the keyword, Shannon finds the real CLI on PATH, remaining argv is\n"
        "passed through untouched.\n"
        "\n"
        f"  {prog} grok\n"
        f"  {prog} codex --full-auto\n"
        f"  {prog} claude -p \"review the auth changes\"\n"
        "\n"
        "Agents:\n"
        f"{rows}\n"
        "\n"
        "Shannon flags (consumed left of the agent argv; `--` ends them):\n"
        "  --dry-run --json --no-gate --task ID --gate-socket PATH\n"
        "  --threshold BITS --window N\n"
        "\n"
        "Entropy monitor (JSONL / OpenAI API):\n"
        f"  {prog} stdin\n"
        f"  {prog} openai --model gpt-4 \"prompt\"\n"
        f"  {prog} info\n"
        "\n"
        "Product split: Shannon CLI = this tool + hub gate/agent tooling;\n"
        "Shannon UI = Pill menu-bar / notch HUD only (./scripts/shannon).\n"
    )


def merge_env(
    extra: Mapping[str, str],
    base: Mapping[str, str] | None = None,
) -> dict[str, str]:
    env = dict(base if base is not None else os.environ)
    env.update(extra)
    return env


def try_attach_gate(plan: LaunchPlan) -> str:
    """Best-effort hub spawn. Never raises. Returns attached|skipped|error."""
    if not plan.attach_gate or plan.gate_status != "attach":
        return "skipped"
    if _agent_manager is None:
        return "skipped"
    try:
        mgr = _agent_manager.AgentManager(socket_path=plan.extra_env["SHANNON_GATE_SOCKET"])
        mgr.spawn(plan.agent_id, plan.task_id, reason="harness")
        return "attached"
    except Exception as exc:  # noqa: BLE001 — fail-open on any gate/client error
        return f"error:{type(exc).__name__}"


def try_detach_gate(plan: LaunchPlan) -> None:
    if not plan.attach_gate or plan.gate_status != "attach":
        return
    if _agent_manager is None:
        return
    try:
        mgr = _agent_manager.AgentManager(socket_path=plan.extra_env["SHANNON_GATE_SOCKET"])
        mgr.kill(plan.agent_id, plan.task_id, reason="harness-exit")
    except Exception:  # noqa: BLE001 — fail-open; the agent has already exited
        return


def run_launch(
    plan: LaunchPlan,
    *,
    environ: Mapping[str, str] | None = None,
) -> int:
    """Run the planned argv with inherited stdio (TUIs behave as a direct invoke)."""
    if not plan.binary_found:
        print(missing_binary_message(plan), file=sys.stderr)
        return 1
    attach_result = try_attach_gate(plan)
    env = merge_env(plan.extra_env, environ)
    if attach_result.startswith("error:"):
        env["SHANNON_GATE_ATTACH"] = attach_result
    elif attach_result == "attached":
        env["SHANNON_GATE_ATTACH"] = "attached"
    else:
        env["SHANNON_GATE_ATTACH"] = plan.gate_status
    try:
        completed = subprocess.run(list(plan.argv), env=env, check=False)
        return int(completed.returncode)
    finally:
        try_detach_gate(plan)


def execute_harness(
    argv: Sequence[str],
    *,
    path: str | None = None,
    gate_socket_exists: bool | None = None,
    stdout=None,
    stderr=None,
    skip_exec: bool = False,
) -> int:
    """Parse argv, plan, and either print or launch. Returns process exit code."""
    out = stdout if stdout is not None else sys.stdout
    err = stderr if stderr is not None else sys.stderr
    try:
        inv = parse_harness_invocation(argv)
    except HarnessUsageError as exc:
        print(f"shannon: {exc}", file=err)
        return 2
    try:
        plan = plan_launch(
            inv.keyword,
            inv.agent_argv,
            path=path,
            task_id=inv.options.task_id,
            attach_gate=inv.options.attach_gate,
            gate_socket=inv.options.gate_socket,
            threshold=inv.options.threshold,
            window=inv.options.window,
            gate_socket_exists=gate_socket_exists,
        )
    except HarnessUsageError as exc:
        print(f"shannon: {exc}", file=err)
        print("Known agents: " + ", ".join(all_primary_keywords()), file=err)
        return 2
    if inv.options.dry_run or skip_exec:
        if inv.options.json_out:
            print(json.dumps(plan.as_dict(), indent=2, sort_keys=True), file=out)
        else:
            print(format_launch_plan_text(plan), file=out, end="")
            if not plan.binary_found:
                print(missing_binary_message(plan), file=err)
        return 0 if plan.binary_found else 1
    return run_launch(plan)
