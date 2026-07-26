# FlexAIDdS + Shannon concurrent benchmarking

**Shannon owns the campaign.** Agents do not invent a parallel orchestration
workflow. All lifecycle traffic goes through the Shannon skill / hub CLI
(`spawn` / `control` / `monitor` / `ask` / `result` / `kill` / `campaign` /
`delegate`).

## Ownership

| Role | Agent id | Responsibility |
|------|----------|----------------|
| **Campaign owner (Shannon)** | — | Plans phases A→B0→B, assigns roles, refuses dual heavy owners |
| Docking engine bridge | `dataset_runner` | Sole heavy-arm owner: `benchmark_update`, file watcher results |
| Science analysis | `science` | tENCoM / entropy / CF disagreement notes (not docking launch) |
| Code changes | `claude_code`, `codex`, `grok_build`, `opencode` | patches via `code_suggestion` + LP approval |
| Coordination | `dispatch` | fan-out, monitor, kill stuck workers |
| Design / UX | `design` | UI specs only — no docking launch |
| Cowork | `cowork` | shared doc / handoff |

## Shannon-owned campaign (preferred)

Dry-run (no gate required):

```bash
export PYTHONPATH="${SHANNON_ROOT:-.}/hub${PYTHONPATH:+:$PYTHONPATH}"

# Plan ownership + delegations (owner = dataset_runner, phases A B0 B)
python3 -m agent_manager campaign \
  --campaign red-pair \
  --owner dataset_runner \
  --analysts science \
  --coders claude_code,codex \
  --coordinator dispatch \
  --dry-run --json

# Dual-owner check: if monitor already shows dataset_runner, plan refuses (exit 3)
python3 -m agent_manager campaign \
  --connected dataset_runner \
  --dry-run --json

# Single role under Shannon ownership
python3 -m agent_manager delegate science --task flexaidds_redpair_YYYYMMDD --dry-run --json
```

Live (gate up): use the same task id from the campaign plan, then
`spawn` / `control` / `result` / `kill` for each delegated agent. Shannon still
owns the **plan**; host TUIs own process launch.

## Protocol

1. **Shannon plans the campaign** (`campaign --dry-run`) — inspect owner + roles.
2. `python3 -m agent_manager monitor` — who is online?
3. If another agent owns a heavy arm, **do not spawn a second owner** (CLI refuses).
4. `spawn <delegated_agent> --task <campaign_task_id>` for each role Shannon assigned.
5. `control` phase lines: `A started`, `B0 packing`, `PoseBusters…`
6. `dataset_runner` emits `result` / benchmark updates with cf/rmsd (never invent).
7. Analysts emit `result` with analysis text — gate scores entropy.
8. Risky code: `ask` or `code_suggestion` — never silent merge.
9. `kill` on exit for every delegated agent.

## Hard bans (from FlexAIDdS skill)

- Serial **one** heavy arm at a time (A→B0→B)
- No Softβ claims that fix BCR=0
- Local-first OUT/work for classic arms
- **No dual `dataset_runner` (or other heavy owner) for the same campaign**

Pin FlexAIDdS skill for science detail; Shannon skill owns **campaign
orchestration + agent lifecycle**.
