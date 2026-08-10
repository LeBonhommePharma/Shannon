# Claude Code ↔ Codex pair work (Shannon-owned)

> Part of the Shannon **SKILL** (`skills/shannon/SKILL.md`). Install via
> `./scripts/shannon skill-install` so host TUIs load this reference.

Shannon plans **who implements** and **who reviews**. Host TUIs (Claude Code,
Codex) still run the real tools; Shannon does not invent review comments or
split a git tree automatically.

**CLI note:** use `--pair-mode` (not `--mode`). Common `--mode` is only
`socket|http` for gate transport.

## Modes (`agent_manager pair --pair-mode`)

| Mode | Claude Code | Codex | Assignments |
|------|-------------|-------|-------------|
| `implement_pair` | implement `slice_a` | implement `slice_b` | 2 |
| `cross_review` | implement `slice_a` + review Codex `slice_b` | implement `slice_b` + review Claude `slice_a` | **4** |
| `claude_implements` | implement `full` | review `full` | 2 |
| `codex_implements` | review `full` | implement `full` | 2 |
| `implement_only` | implement `full` (solo; not a pair) | — | 1 |

> **Assignment count is not agent count.** `cross_review` emits **4 assignments
> for 2 agents** — each `agent_id` appears twice, once `role: implement` and once
> `role: review`. It is not one object per agent with a merged role. Spawn once
> per distinct entry in `agents[]`, never `len(assignments)` times.

### Choosing non-default agents

`--agent-a` / `--agent-b` override the pair (defaults `claude_code` / `codex`);
ids are normalized first, so `--agent-a grok` works.

- **Honoured** by `implement_pair`, `cross_review`, `implement_only`. e.g.
  `--agent-a grok_build --agent-b opencode` yields a grok_build/opencode pair,
  and grok_build alone for `implement_only`.
- **Silently ignored** by `claude_implements` and `codex_implements` — those two
  hardcode `claude_code` + `codex` regardless of what you pass, with no refusal
  and no warning. If you need a non-default pair with a single implementer, use
  `implement_pair` or `implement_only` instead.

## Dry-run (no gate — `pair` never contacts the gate at all)

```bash
export PYTHONPATH="${SHANNON_ROOT:-.}/hub${PYTHONPATH:+:$PYTHONPATH}"

python3 -m agent_manager pair --pair-mode implement_pair \
  --task pair_auth_YYYYMMDD --summary "Auth + tests" --dry-run --json

python3 -m agent_manager pair --pair-mode cross_review \
  --task pair_xr_YYYYMMDD --summary "Feature X" --dry-run --json

python3 -m agent_manager pair --pair-mode claude_implements \
  --task pair_ci_YYYYMMDD --dry-run --json

python3 -m agent_manager pair --pair-mode codex_implements \
  --task pair_xi_YYYYMMDD --dry-run --json
```

Output is identical with and without `--dry-run` — `pair` is a pure planner.

## Reading the plan JSON

- `task_id` — shared by every agent in the pair; reuse it verbatim.
- `agents` — a **sorted, deduplicated list of agent-id strings**
  (`["claude_code", "codex"]`), not an object and not one entry per assignment.
  One entry for `implement_only`; `[]` on a refusal.
- `assignments[]` — each has `role` (`implement` | `review`), `slice`
  (`slice_a` | `slice_b` | `full`), and a `plan` spawn dict.
- `fabricated_review` / `fabricated_code` — top-level keys, always `null`.

## Refusals

`--pair-mode` has no argparse `choices`, so an unknown value is a **soft
refusal**, not a crash: `refused: true`, `refuse_reason` naming the five valid
modes, `assignments: []`, `agents: []` — and **exit 0**. Check `refused`, not
the exit status.

## Live session (gate up)

1. Shannon: `pair --dry-run --json` → note `task_id` and assignments.
2. Spawn **once per distinct entry in `agents[]`**:
   `spawn <agent_id> --task <task_id>`. In `cross_review` each agent appears in
   two assignments — spawn it once and drive both roles through `control`.
3. `control` with phase lines, e.g. `implement slice_a started`,
   `review slice_b ready`.
4. `result` with real findings (never invent). Set `--confidence` honestly — it
   defaults to 0.9.
5. Risky merges: `ask` for human approval.
6. `kill` every spawned agent on the same `task_id` when done.

## Hard rules

- Shannon owns orchestration — do not freestyle a second pair plan outside the skill.
- Half-and-half is a **slice label**, not automatic file partitioning.
- Plan JSON never contains fabricated review text or code.
