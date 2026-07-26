---
name: shannon
description: >
  Shannon hub agent manager handrail — Shannon owns FlexAIDdS benchmark
  campaign orchestration and delegates collaborative agents (Codex, Claude Code,
  Claude Science, Claude Cowork, Dispatch, Design, Grok Build, OpenCode,
  DatasetRunner) through the Shannon Gate regardless of which upstream model API
  they use. Use for multi-agent FlexAIDdS benchmarking ownership, campaign
  plan/delegate, hub attach, gate status, approval asks, and when any agent must
  report lifecycle/status/results to the Shannon pill.
  Triggers: /shannon, "shannon hub", "attach agent", "spawn agent",
  "monitor agents", "kill agent", "campaign", "delegate", concurrent agentic
  benchmarking.
---

# Shannon — Hub Agent Handrail

**Shannon owns multi-agent workstreams — especially FlexAIDdS benchmarking.**
Upstream models (Claude, Codex, Grok, OpenCode, …) may use any API endpoint.
They must still be **delegated through this skill** (spawn / control / monitor /
ask / result / kill / campaign / delegate) so concurrent work stays observable,
gated, and killable from one place (pill + gate + this skill).

Agents must **not** invent a parallel orchestration workflow. If Shannon has not
planned the campaign and delegated your role, do not dual-launch a heavy docking
arm.

## When to use

- **Owning** a FlexAIDdS / Astex / red-pair benchmark campaign (Shannon plans it)
- Delegating science / code / dispatch agents into campaign roles
- Starting or joining a multi-agent session through the hub
- Reporting progress, results, or approval needs to the human via the pill
- Listing who is online / detaching a stuck agent
- Any host TUI (Claude Code, Codex, Grok Build, OpenCode, Cowork, Dispatch, Design)

## Hard rules

1. **Shannon owns the campaign plan.** Use `campaign` (dry-run OK) before multi-agent docking work.
2. **Register before heavy work.** `spawn` (or attach) your agent id + **campaign task id**.
3. **Status heartbeats** on long runs (`control` every meaningful phase: A → B0 → B).
4. **Results go through the gate** (`result`) — entropy-scored, audited; never invent CF/RMSD/H.
5. **Human approvals** via `ask` — never silent force-push of gated actions.
6. **Detach on exit** (`kill`) so the pill does not show ghost agents.
7. **No dual heavy docking owner.** `dataset_runner` is the sole docking owner role; `monitor` first. The CLI **refuses** a second heavy owner when monitor/connected state already shows one.
8. Shannon does **not** replace host process kill (⌘C / TUI cancel). `kill` is hub detach; pair with host-native cancel when stopping compute.

## Canonical agent ids

| Id | Display | Typical host |
|----|---------|--------------|
| `grok_build` | Grok Build | Grok / xAI TUI |
| `codex` | Codex | OpenAI Codex |
| `claude_code` | Claude Code | Claude Code CLI |
| `science` | Claude Science | Science / Fable |
| `cowork` | Cowork | Claude Cowork |
| `dispatch` | Dispatch | Claude Dispatch |
| `design` | Claude Design | Claude Design app / design CLI / artifacts canvas |
| `opencode` | OpenCode | OpenCode TUI |
| `dataset_runner` | DatasetRunner | FlexAIDdS bridge (**heavy docking owner**) |

Aliases accepted by the CLI: `grok`→`grok_build`, `claude`→`claude_code`, `sci`→`science`, `claude_design`/`des`→`design`, `oc`→`opencode`, `dr`→`dataset_runner`, …

Full roster: `references/agents.md`.

## CLI (preferred)

From Shannon repo root (gate must be running for **live** cmds; **`--dry-run` always works**):

```bash
# Ensure hub PYTHONPATH
export PYTHONPATH="${SHANNON_ROOT:-.}/hub${PYTHONPATH:+:$PYTHONPATH}"

# Gate up?
python3 -m agent_manager gate-status

# Roster (no gate needed)
python3 -m agent_manager roster

# ── Shannon-owned campaign (orchestration; no gate for dry-run) ──
python3 -m agent_manager campaign \
  --campaign red-pair \
  --owner dataset_runner \
  --analysts science \
  --coders claude_code,codex \
  --coordinator dispatch \
  --dry-run --json

# Dual-owner refusal check (synthetic monitor roster)
python3 -m agent_manager campaign --connected dataset_runner --dry-run --json

# Single role under Shannon ownership
python3 -m agent_manager delegate science --task flexaidds_redpair_YYYYMMDD --dry-run --json

# Lifecycle (dry-run / offline)
python3 -m agent_manager spawn science --dry-run --json
python3 -m agent_manager control science "docking 1ACJ" --task TASK --dry-run
python3 -m agent_manager monitor --dry-run
python3 -m agent_manager kill science --task TASK --dry-run

# Live (needs ./scripts/shannon gate or hub running)
python3 -m agent_manager spawn dataset_runner --task flexaidds_redpair_YYYYMMDD --reason "campaign owner"
python3 -m agent_manager spawn science --task flexaidds_redpair_YYYYMMDD
python3 -m agent_manager control dataset_runner "phase A started" --task flexaidds_redpair_YYYYMMDD
python3 -m agent_manager monitor
python3 -m agent_manager ask science "Approve Softβ election?" --task flexaidds_redpair_YYYYMMDD
python3 -m agent_manager result dataset_runner --task flexaidds_redpair_YYYYMMDD \
  --payload '{"target_id":"1ACJ","cf_value":-3.21,"rmsd":1.4}'
python3 -m agent_manager kill science --task flexaidds_redpair_YYYYMMDD --reason "session end"
```

Or via bootstrap script (`agent` / `agents` / `hub-agent` — **not** `hub`,
which bootstraps the macOS app):

```bash
./scripts/shannon agent roster
./scripts/shannon agent campaign --dry-run --json
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
3. Shannon plans campaign: agent_manager campaign --dry-run --json  → task_id
4. monitor — refuse second heavy owner if dataset_runner already online
5. spawn <your_delegated_agent_id> --task $task_id
6. loop: control … / result … / ask … as needed (phases A → B0 → B)
7. kill <your_agent_id> --task $task_id on exit (success or fail)
```

## FlexAIDdS concurrent benchmarking

See `references/flexaidds.md`. Summary:

- **Shannon owns** the campaign plan and role map.
- One heavy classic arm at a time on one Mac (A → B0 → B).
- `dataset_runner` is the only heavy docking owner; science/codex/grok analyze — do not dual-launch owners.
- Always `monitor` (or `campaign --connected …`) before spawn of a second docking owner.

## Failure modes

| Symptom | Action |
|---------|--------|
| `gate offline` | `./scripts/shannon gate` or start hub; pill may auto-ensure |
| `Unknown agent_id` | Use roster ids; add identity in `hub/agent_identity.py` if new host |
| Campaign refused (exit 3) | Heavy owner already online — monitor / kill existing, then re-plan |
| Ghost agent on pill | `kill` with same task_id; or wait for heartbeat expiry |
| Approval stuck | Human answers in pill; agent must not invent approval |

## Implementation map

| Piece | Path |
|-------|------|
| Gate daemon | `hub/shannon_gate.py` |
| Client | `hub/agent_protocol.py` |
| Lifecycle + **campaign ownership** | `hub/agent_manager.py` |
| Identities | `hub/agent_identity.py` |
| macOS pill | `Pill/` |
| This skill | `skills/shannon/` |
