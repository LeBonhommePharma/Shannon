# Claude Code ↔ Codex pair work (Shannon-owned)

> Part of the Shannon **SKILL** (`skills/shannon/SKILL.md`). Install via
> `./scripts/shannon skill-install` so host TUIs load this reference.

Shannon plans **who implements** and **who reviews**. Host TUIs (Claude Code,
Codex) still run the real tools; Shannon does not invent review comments or
split a git tree automatically.

**CLI note:** use `--pair-mode` (not `--mode`). Common `--mode` is only
`socket|http` for gate transport.

## Modes (`agent_manager pair --pair-mode`)

| Mode | Claude Code | Codex |
|------|-------------|-------|
| `implement_pair` | implement `slice_a` | implement `slice_b` |
| `cross_review` | implement `slice_a` + review Codex `slice_b` | implement `slice_b` + review Claude `slice_a` |
| `claude_implements` | implement `full` | review `full` |
| `codex_implements` | review `full` | implement `full` |
| `implement_only` | implement `full` (solo; not a pair) | — |

## Dry-run (no gate)

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

Inspect JSON: shared `task_id`, `agents` (`claude_code`, `codex`), each
assignment has `role` (`implement`|`review`), `slice`, and a `plan` spawn dict.

## Live session (gate up)

1. Shannon: `pair --dry-run --json` → note `task_id` and assignments.
2. For each assignment: `spawn <agent_id> --task <task_id>`.
3. `control` with phase lines, e.g. `implement slice_a started`, `review slice_b ready`.
4. `result` with real findings (never invent).
5. Risky merges: `ask` for human approval.
6. `kill` both agents on the same `task_id` when done.

## Hard rules

- Shannon owns orchestration — do not freestyle a second pair plan outside the skill.
- Half-and-half is a **slice label**, not automatic file partitioning.
- Plan JSON never contains fabricated review text or code (`fabricated_review` / `fabricated_code` are always null).
