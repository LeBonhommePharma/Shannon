---
name: shannon
description: >
  Shannon hub agent manager handrail — spawn, control, monitor, and kill
  collaborative agents (Codex, Claude Code, Claude Science, Claude Cowork,
  Dispatch, Design, Grok Build, OpenCode) through the Shannon Gate regardless
  of which upstream model API they use. Use for multi-agent FlexAIDdS
  benchmarking coordination, hub attach, gate status, approval asks, and
  when any agent must report lifecycle/status/results to the Shannon pill.
  Triggers: /shannon, "shannon hub", "attach agent", "spawn agent",
  "monitor agents", "kill agent", concurrent agentic benchmarking.
---

# Shannon — Hub Agent Handrail

**Shannon is the downstream agentic management hub.** Upstream models (Claude,
Codex, Grok, OpenCode, …) may use any API endpoint. They must still register,
report, and detach through Shannon so concurrent work on collaborative
projects — especially FlexAIDdS benchmarking — stays observable, gated, and
killable from one place (pill + gate + this skill).

## When to use

- Starting or joining a multi-agent session
- Concurrent FlexAIDdS / Astex entropy benchmarking across agents
- Reporting progress, results, or approval needs to the human via the pill
- Listing who is online on the hub / detaching a stuck agent
- Any host TUI (Claude Code, Codex, Grok Build, OpenCode, Cowork, Dispatch, Design)

## Hard rules

1. **Register before heavy work.** `spawn` (or attach) your agent id + task id.
2. **Status heartbeats** on long runs (`control` every meaningful phase).
3. **Results go through the gate** (`result`) — entropy-scored, audited.
4. **Human approvals** via `ask` — never silent force-push of gated actions.
5. **Detach on exit** (`kill`) so the pill does not show ghost agents.
6. **No duplicate launch** of the same FlexAIDdS arm if hub already shows an owner — `monitor` first.
7. Shannon does **not** replace host process kill (⌘C / TUI cancel). `kill` is hub detach; pair with host-native cancel when stopping compute.

## Canonical agent ids

| Id | Display | Typical host |
|----|---------|--------------|
| `grok_build` | Grok Build | Grok / xAI TUI |
| `codex` | Codex | OpenAI Codex |
| `claude_code` | Claude Code | Claude Code CLI |
| `science` | Claude Science | Science / Fable |
| `cowork` | Cowork | Claude Cowork |
| `dispatch` | Dispatch | Claude Dispatch |
| `design` | Design | Design agents |
| `opencode` | OpenCode | OpenCode TUI |
| `dataset_runner` | DatasetRunner | FlexAIDdS bridge |

Aliases accepted by the CLI: `grok`→`grok_build`, `claude`→`claude_code`, `sci`→`science`, `oc`→`opencode`, …

Full roster: `references/agents.md`.

## CLI (preferred)

From Shannon repo root (gate must be running for live cmds; `--dry-run` always works):

```bash
# Ensure hub PYTHONPATH
export PYTHONPATH="${SHANNON_ROOT:-.}/hub${PYTHONPATH:+:$PYTHONPATH}"

# Gate up?
python3 -m agent_manager gate-status

# Roster (no gate needed)
python3 -m agent_manager roster

# Dry-run plans (tests / offline)
python3 -m agent_manager spawn science --dry-run --json
python3 -m agent_manager control science "docking 1ACJ" --task TASK --dry-run
python3 -m agent_manager monitor --dry-run
python3 -m agent_manager kill science --task TASK --dry-run

# Live (needs ./scripts/shannon gate or hub running)
python3 -m agent_manager spawn claude_code --reason "flexaidds red-pair"
python3 -m agent_manager control claude_code "phase A started" --task TASK
python3 -m agent_manager monitor
python3 -m agent_manager ask science "Approve Softβ election?" --task TASK
python3 -m agent_manager result dataset_runner --task TASK \
  --payload '{"target_id":"1ACJ","cf_value":-3.21,"rmsd":1.4}'
python3 -m agent_manager kill claude_code --task TASK --reason "session end"
```

Or via bootstrap script (`agent` / `agents` / `hub-agent` — **not** `hub`,
which bootstraps the macOS app):

```bash
./scripts/shannon agent roster
./scripts/shannon agent spawn science --dry-run
./scripts/shannon agent monitor
./scripts/shannon agent control science "phase A" --task TASK --dry-run
./scripts/shannon agent kill science --task TASK --dry-run
```

## Install into host TUIs

```bash
# From Shannon repo — installs/symlinks skill into Claude, Codex, Grok, OpenCode, agents/
python3 skills/shannon/scripts/install_skill.py
# or
./scripts/shannon skill-install
```

Installs into (when present):

- Project: `.claude/skills/shannon`, `.grok/skills/shannon`, `.agents/skills/shannon`
- User: `~/.claude/skills/shannon`, `~/.codex/skills/shannon`, `~/.grok/skills/shannon`
- OpenCode: `~/.config/opencode/skills/shannon` (if config tree exists)
- FlexAIDdS sibling (optional): `~/Projects/FlexAIDdS/.agents/skills/shannon`

## Session protocol (copy into agent system notes)

```
1. SHANNON_ROOT = path to Shannon checkout
2. PYTHONPATH=$SHANNON_ROOT/hub
3. task_id = stable id for this workstream (e.g. flexaidds_redpair_YYYYMMDD)
4. spawn <my_agent_id> --task $task_id
5. loop: control … / result … / ask … as needed
6. monitor before starting another heavy arm
7. kill <my_agent_id> --task $task_id on exit (success or fail)
```

## FlexAIDdS concurrent benchmarking

See `references/flexaidds.md`. Summary:

- One heavy classic arm at a time on one Mac (A → B0 → B).
- `dataset_runner` owns benchmark_update; science/codex/grok analyze — do not dual-launch.
- Always `monitor` before spawn of a second docking owner.

## Failure modes

| Symptom | Action |
|---------|--------|
| `gate offline` | `./scripts/shannon gate` or start hub; pill may auto-ensure |
| `Unknown agent_id` | Use roster ids; add identity in `hub/agent_identity.py` if new host |
| Ghost agent on pill | `kill` with same task_id; or wait for heartbeat expiry |
| Approval stuck | Human answers in pill; agent must not invent approval |

## Implementation map

| Piece | Path |
|-------|------|
| Gate daemon | `hub/shannon_gate.py` |
| Client | `hub/agent_protocol.py` |
| Lifecycle | `hub/agent_manager.py` |
| Identities | `hub/agent_identity.py` |
| macOS pill | `Pill/` |
| This skill | `skills/shannon/` |
