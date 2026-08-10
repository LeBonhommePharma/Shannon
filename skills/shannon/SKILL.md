---
name: shannon
description: >
  Shannon hub agent manager handrail — Shannon owns FlexAIDdS benchmark
  campaign orchestration and Claude Code ↔ Codex pair work (half-and-half
  implement + cross-review), and delegates collaborative agents (Codex, Claude
  Code, Claude Science, Claude Cowork, Dispatch, Design, Grok Build, OpenCode,
  DatasetRunner) through the Shannon Gate regardless of which upstream model API
  they use. It also prepares resumable, evidence-complete handoffs to Claude
  Code, Dispatch, or dependency-ordered Claude Science/Fable session packs from
  an in-flight dirty checkout. Use for multi-agent FlexAIDdS ownership,
  pair/cross-review, Fable multi-session handoff, handoff/resume/transfer,
  plan/delegate, hub attach, gate status, approval asks, and when any agent must
  report lifecycle/status/results to the Shannon pill.
  Triggers: /shannon, "shannon hub", "attach agent", "spawn agent",
  "monitor agents", "kill agent", "campaign", "delegate", "pair",
  "cross-review", concurrent agentic benchmarking.
---

# Shannon — Hub Agent Handrail

**Shannon owns multi-agent workstreams — especially FlexAIDdS benchmarking.**
Upstream models (Claude, Codex, Grok, OpenCode, …) may use any API endpoint.
They must still be **delegated through this skill** (spawn / control / monitor /
ask / result / kill / campaign / delegate / **pair**) so concurrent work stays
observable, gated, and killable from one place (pill + gate + this skill).

Agents must **not** invent a parallel orchestration workflow. If Shannon has not
planned the campaign or pair and delegated your role, do not freestyle dual
owners or dual reviewers.

## When to use

- **Owning** a FlexAIDdS / Astex / red-pair benchmark campaign (Shannon plans it)
- **Pair work:** Claude Code ↔ Codex half-and-half implement, or cross-review
  (Codex reviews Claude’s slice and vice-versa)
- Preparing or resuming a Claude Code / Dispatch handoff from active work
- Preparing dependency-ordered Claude Science / Fable multi-session handoffs
- Delegating science / code / dispatch agents into campaign roles
- Starting or joining a multi-agent session through the hub
- Reporting progress, results, or approval needs to the human via the pill
- Listing who is online / detaching a stuck agent
- Any host TUI (Claude Code, Codex, Grok Build, OpenCode, Cowork, Dispatch, Design)

## ⚠ Known breakage — read before you plan

**Live `monitor` hangs forever.** The client sets no read timeout
(`hub/agent_protocol.py:405` `settimeout(None)`), so a gate that accepts the
connection but never answers the `agent_list` query blocks the CLI indefinitely
— while `gate-status` still cheerfully reports `gate_up: true`. Always wrap it:

```bash
timeout 20 python3 -m agent_manager monitor --agent <your_id> --task <your_task> --json
```

Exit **124** means it hung, and you therefore have **no roster**. Do not treat
that as "nobody is online": treat connected state as **UNKNOWN**, do not spawn a
heavy owner, and ask the human via the pill. `monitor --dry-run` is *not* a
fallback — it echoes the query plan and returns no roster at all.

**`monitor` is read-only on data but NOT passive on identity.** It opens a real
gate session and registers. With no flags it registers as **`dispatch`**
(`hub/agent_manager.py:1191`), and the gate *replaces* any existing connection
for that id — a bare `monitor` can knock a live Dispatch off the pill. Always
pass `--agent <your own id> --task <your task id>`.

## Hard rules

1. **Shannon owns the campaign plan.** Use `campaign` before multi-agent docking
   work. `campaign`, `delegate` and `pair` are **pure planners** — they never
   open a gate connection and never launch anything, so `--dry-run` changes
   nothing on them. Planning is not registering.
2. **Shannon owns Claude Code ↔ Codex pair plans.** Use `pair --pair-mode …` (not
   freestyle dual implementers/reviewers). Flag is **`--pair-mode`** — common
   `--mode` is only `socket|http`.
3. **Register before heavy work.** `spawn` (or attach) your agent id + the
   **campaign/pair task id**. If the gate cannot be brought up, heavy work is
   forbidden — do not fabricate registration; fall back to dry-run plans and say
   so.
4. **Status heartbeats** on long runs (`control` every meaningful phase:
   A → B0 → B, or implement/review slices).
5. **Results go through the gate** (`result`) — entropy-scored, audited; never
   invent CF/RMSD/H or review findings. Set `--confidence` honestly; it defaults
   to **0.9**, so an unqualified result silently self-reports high confidence.
6. **Human approvals** via `ask` — never silent force-push of gated actions.
7. **Detach on exit** (`kill`) so the pill does not show ghost agents. Waiting
   does not clear a ghost: after 300 s the gate only demotes `active` → `idle`.
8. **No dual heavy docking owner.** `dataset_runner` is the sole docking owner
   role — **and the guard is manual.** `campaign`/`delegate` never query the hub;
   they refuse (exit 3) only against the roster **you** hand them via
   `--connected <ids>`. A bare plan returns `refused: false` even while a heavy
   owner is live, and `spawn` has no guard at all. So: establish who is online
   first, then re-plan with `--connected` and treat exit 3 as a hard stop.
   - Pass **canonical ids only**. `--connected DatasetRunner` (the *Display*
     string) normalizes to `datasetrunner`, matches nothing, and **silently
     passes** the guard. Use `dataset_runner` / `dr` / `dataset`.
   - Never pass `--owner` anything but `dataset_runner`; only it is in
     `HEAVY_DOCKING_OWNER_IDS`, so any other owner disables the refusal entirely.
9. Shannon does **not** replace host process kill (⌘C / TUI cancel). `kill` is
   hub detach; use host-native cancel when stopping compute.

## Canonical agent ids

The 8 ids below are the **handrail roster** — exactly what
`python3 -m agent_manager roster` prints (`HANDRAIL_AGENT_IDS`).

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

**`dataset_runner` (DatasetRunner) — the heavy docking owner — is a valid
canonical id that `roster` does NOT print.** The gate accepts 17 ids
(`IDENTITIES` = `VALID_AGENTS`); `roster` shows only the 8 collaborative
workers. Never conclude an id is invalid because `roster` omitted it.

**Pick your own id by host process, not by task:** a Claude Code CLI session is
`claude_code` even when doing science work; `science` is reserved for Claude
Science / Fable sessions.

Aliases are normalized (trim, lower-case, spaces/hyphens → `_`) before lookup:
`grok`→`grok_build`, `claude`→`claude_code`, `sci`→`science`, `des`→`design`,
`oc`→`opencode`, `dr`/`dataset`→`dataset_runner`, …

Tiers, full alias table, and the extended ids: **`references/agents.md`**.
Complete flag / exit-code / JSON-field reference: **`references/cli.md`**.

## CLI (preferred)

Run from the Shannon repo root, or export `SHANNON_ROOT` yourself —
**no Shannon code reads `SHANNON_ROOT`; it is a doc convention only.**

> `--dry-run` does **not** validate the agent id. `normalize_agent_id` passes any
> unrecognised slug through and a placeholder identity is synthesized, so
> `spawn bogus_agent --dry-run` returns a plausible plan with **exit 0**.
> Rejection happens only on the live path. A generic ⚙️ label in plan JSON means
> you used a non-canonical id — canonical ids carry their own emoji (📊 for
> DatasetRunner).

**Common flags (every subcommand):** `--json` · `--mode socket|http` (default
`socket`) · `--socket PATH` (default `/tmp/shannon.sock`, no env override) ·
`--http-url URL` (default `http://127.0.0.1:8765`).

```bash
# Ensure hub PYTHONPATH
export PYTHONPATH="${SHANNON_ROOT:-.}/hub${PYTHONPATH:+:$PYTHONPATH}"

# Gate up?  exit 0 = up, exit 2 = down. Probes the SOCKET only — gate-status
# ignores --mode. It connects rather than stats, so a stale socket reads down.
python3 -m agent_manager gate-status

# Roster (no gate needed) — prints the 8 handrail ids, NOT dataset_runner
python3 -m agent_manager roster

# ── Shannon-owned campaign (pure planner; never touches the gate) ──
# --task PINS the id. Omit it and every re-plan mints a fresh
# flexaidds_<campaign>_<epoch>_<hex8>, silently orphaning agents already
# spawned on the previous id. Campaign slugs: red-pair | astex | hap2 | casf.
python3 -m agent_manager campaign \
  --campaign red-pair \
  --task "$TASK_ID" \
  --owner dataset_runner \
  --analysts science \
  --coders claude_code,codex \
  --coordinator dispatch \
  --dry-run --json

# Dual-owner refusal check — the roster is SYNTHETIC, supplied by you.
# Exits 3 with refused:true when a canonical heavy-owner id is present.
python3 -m agent_manager campaign --connected dataset_runner --dry-run --json

# Single role under Shannon ownership (role tokens: references/cli.md)
python3 -m agent_manager delegate docking_owner --task "$TASK_ID" --dry-run --json

# ── Claude Code ↔ Codex pair (pure planner) ──
# Half-and-half implement (slice_a / slice_b)
python3 -m agent_manager pair --pair-mode implement_pair \
  --task "$PAIR_TASK" --summary "Auth middleware + tests" --dry-run --json

# Mutual cross-review (each implements one slice and reviews the other)
python3 -m agent_manager pair --pair-mode cross_review \
  --task "$PAIR_TASK" --summary "Feature X" --dry-run --json

# Claude implements full; Codex reviews  (also: codex_implements, implement_only)
python3 -m agent_manager pair --pair-mode claude_implements \
  --task "$PAIR_TASK" --summary "Implement feature" --dry-run --json

# Which Mac takes the next heavy arm? (pure planner; pass JSON INLINE —
# the `--devices -` stdin form advertised by --help is currently broken)
python3 -m agent_manager prefer-device \
  --devices '[{"device_id":"mac1","cpu_percent":10},{"device_id":"mac2","cpu_percent":90}]' \
  --busy-threshold 85 --json

# Lifecycle (dry-run / offline)
python3 -m agent_manager spawn science --dry-run --json
python3 -m agent_manager control science "docking 1ACJ" --task "$TASK_ID" --dry-run
python3 -m agent_manager kill science --task "$TASK_ID" --dry-run

# Live (needs ./scripts/shannon gate or hub running).
# $TASK_ID = the exact task_id string emitted by the campaign plan.
python3 -m agent_manager spawn dataset_runner --task "$TASK_ID" --reason "campaign owner"
python3 -m agent_manager spawn science --task "$TASK_ID"
python3 -m agent_manager control dataset_runner "phase A started" --task "$TASK_ID"
timeout 20 python3 -m agent_manager monitor --agent science --task "$TASK_ID"   # see Known breakage
python3 -m agent_manager ask science "Approve Softβ election?" --task "$TASK_ID"
python3 -m agent_manager result dataset_runner --task "$TASK_ID" --confidence 0.75 \
  --payload '{"target_id":"1ACJ","cf_value":-3.21,"rmsd":1.4}'   # or --payload - for stdin
python3 -m agent_manager kill science --task "$TASK_ID" --reason "session end"
```

Or via the bootstrap script — use **`agent` / `agents` / `hub-agent`** only:

```bash
./scripts/shannon agent roster
./scripts/shannon agent campaign --dry-run --json
./scripts/shannon agent pair --pair-mode implement_pair --task pair_t1 --dry-run --json
./scripts/shannon agent spawn science --dry-run
./scripts/shannon agent control science "phase A" --task "$TASK_ID" --dry-run
./scripts/shannon agent kill science --task "$TASK_ID" --dry-run
```

> **Do not** run `./scripts/shannon` with **no arguments**, nor `hub`,
> `bootstrap`, or `up` — all four hit the same `bootstrap_all` case: it creates
> pets, starts the gate, runs the pill bridge demo, and launches the macOS GUI
> (building it from source if absent). `./scripts/shannon gate` is the narrow,
> safe way to bring the gate up.

## Install into host TUIs

```bash
# Preview every destination on this host, change nothing
python3 skills/shannon/scripts/install_skill.py --dry-run

# Install as SYMLINKS so each host reads the live repo copy (recommended in a dev checkout)
python3 skills/shannon/scripts/install_skill.py --symlink

# Default (no flag) is a recursive COPY — a frozen snapshot that will NOT track later edits
python3 skills/shannon/scripts/install_skill.py
# ./scripts/shannon skill-install forwards "$@" verbatim and adds no flags
```

`--force` also creates host trees that do not exist yet. Destinations that are
already symlinks into this repo are skipped, so re-running is safe.

Destinations (written only where the parent tree already exists):

- Project: `.claude/skills/shannon`, `.grok/skills/shannon`, `.agents/skills/shannon`
- User: `~/.claude/skills/shannon`, `~/.codex/skills/shannon`, `~/.grok/skills/shannon`
- OpenCode: `~/.config/opencode/skills/shannon` **and** `~/.opencode/skills/shannon`
- FlexAIDdS sibling (path hardcoded to `~/Projects/FlexAIDdS`): `.agents/`,
  `.claude/`, and `.grok/skills/shannon` — note this writes into a *different*
  git repo; check `git status` there afterwards.

## Session protocol (copy into agent system notes)

**Campaign (FlexAIDdS / multi-agent docking):**

```
1. SHANNON_ROOT = path to Shannon checkout (you must export it; no code reads it)
2. PYTHONPATH=$SHANNON_ROOT/hub
3. Shannon plans campaign: agent_manager campaign --task $TASK_ID --dry-run --json
   Read out: ok (false ⇒ refused, exit 3) · task_id (reuse VERBATIM everywhere)
   · owner_agent_id · phases ["A","B0","B"] · delegations[].agent_id / .role
   · existing_heavy_owner. fabricated_entropy / fabricated_cf are always null —
   never populate them.
4. timeout 20 agent_manager monitor --agent <you> --task $TASK_ID — who is online?
   exit 124 ⇒ roster UNKNOWN ⇒ do NOT spawn a heavy owner; ask the human.
5. Re-plan with what you saw: campaign --connected <ids> — exit 3 is a hard stop
6. spawn <your_delegated_agent_id> --task $TASK_ID
7. loop: control … / result … / ask … as needed (phases A → B0 → B)
8. kill <your_agent_id> --task $TASK_ID on exit (success or fail)
```

**Pair (Claude Code ↔ Codex):**

```
1. SHANNON_ROOT + PYTHONPATH as above
2. Shannon plans pair: agent_manager pair --pair-mode <mode> --task $PAIR_TASK --dry-run --json
3. Read assignments (role=implement|review, slice=slice_a|slice_b|full)
4. spawn once per distinct id in the plan's agents[] — NOT once per assignment,
   and do not hardcode two: implement_only emits one agent, cross_review emits
   4 assignments for 2 agents.
5. loop: control (implement/review phases) / result (real findings only) / ask (risky merges)
6. kill every spawned agent on the same task_id when done
```

## Claude Code ↔ Codex pair work

Canonical detail: **`references/pair_work.md`** (part of this **SKILL**). Summary:

- **Shannon owns** the pair plan: `pair --pair-mode … --dry-run --json`.
- Modes: `implement_pair` (half-and-half), `cross_review` (vice-versa review),
  `claude_implements`, `codex_implements`, `implement_only`.
- Shared `task_id`; roles are `implement` / `review` with slice labels — not
  automatic file splits; host TUIs do the real work after `spawn`.
- Spawn from `agents[]` (a sorted, deduplicated list of id strings), never from
  `len(assignments)`.
- Plan JSON never invents review text or code (`fabricated_review` /
  `fabricated_code` exist at top level and are always `null`).

## Resumable handoffs

For a handoff of current work, read **`references/handoff.md`** and follow its
freeze, receipt, artifact, and verification protocol. A request to *prepare* a
handoff authorizes a handoff artifact and optional dry-run task plan; it does
not authorize a live spawn, commit, push, merge, or destructive cleanup.

Use `implement_only` when Claude Code becomes the sole implementer. Use a
Dispatch prompt when Dispatch will coordinate disjoint worker lanes; Dispatch
must not make multiple agents edit the same shared files concurrently.

For two or more Claude Science/Fable sessions, read
**`references/fable_handoffs.md`**. Do not register multiple live sessions under
the single canonical `science` identity. Never interrupt an existing science
experiment to make room for a code-remediation handoff.

## FlexAIDdS concurrent benchmarking

See `references/flexaidds.md`. Summary:

- **Shannon owns** the campaign plan and role map.
- One heavy classic arm at a time on one Mac (A → B0 → B).
- `dataset_runner` is the only heavy docking owner; science/codex/grok analyze —
  do not dual-launch owners.
- The dual-owner refusal only fires on a `--connected` roster you supply
  yourself. Establish who is online *before* planning, not after.

## Failure modes

| Symptom | Action |
|---------|--------|
| `monitor` hangs, exit 124 under `timeout` | Client has no read timeout (`agent_protocol.py:405`). You have **no roster** — treat connected state as UNKNOWN, do not spawn a heavy owner, ask the human. `--dry-run` is not a fallback. |
| Dispatch vanished from the pill | Someone ran a bare `monitor`; it registers as `dispatch` and the gate replaces the existing connection. Always `monitor --agent <your id>`. |
| `gate offline` / `gate-status` exit 2 | `gate-status` connects rather than stats, so a stale `/tmp/shannon.sock` from a dead gate reads down. `./scripts/shannon gate` removes a stale socket before relaunch — but only when no `shannon_gate.py` is alive. If it says "already running" while `gate-status` stays exit 2, the gate is wedged: `pkill -f shannon_gate.py`, then `./scripts/shannon gate`. If it cannot be brought up, hard rule 3 forbids heavy work. |
| Typo'd / unknown agent id | The CLI does **not** reject it — `--dry-run` plans it and exits 0 with a generic ⚙️ label. Only a live call raises (`Unknown agent_id`, exit 1) — and that error prints the full 17-id valid set, which is the list to trust, not `roster`. Add genuinely new hosts to `IDENTITIES` in `hub/agent_identity.py` **and restart the gate**. |
| Campaign **or `delegate`** refused (exit 3) | A canonical heavy-owner id is in the `--connected` roster you passed. Kill the existing owner, then re-plan. |
| Guard did *not* refuse but an owner is live | You passed a Display string (`DatasetRunner`) or a non-`dataset_runner` `--owner`. Re-run with the canonical id. |
| `pair` argparse conflict | Use **`--pair-mode`**, not `--mode` (`--mode` is socket\|http only). An unknown `--pair-mode` value is a soft refusal: `refused: true`, empty `agents[]`. |
| Ghost agent on pill | `kill <agent> --task <same task_id>`. Waiting does **not** clear it — after 300 s idle the gate only demotes `active` → `idle`. |
| Approval stuck | Human answers in pill; agent must not invent approval |

## Implementation map

| Piece | Path |
|-------|------|
| Gate daemon | `hub/shannon_gate.py` |
| Client | `hub/agent_protocol.py` |
| Lifecycle + **campaign + pair ownership** | `hub/agent_manager.py` |
| Identities | `hub/agent_identity.py` |
| FlexAIDdS ↔ hub bridge | `hub/tools/dataset_runner_bridge.py` |
| macOS pill (Shannon UI) | **Not in this repo** — extracted to `LeBonhommePharma/ShannonUI` (commit `18e4226`). Resolved by `scripts/lib_shannon_ui.sh` via `$SHANNON_UI_ROOT` (sticky), then `../ShannonUI`, then `~/Projects/ShannonUI`. See `docs/SHANNON_UI.md`. |
| This **SKILL** | `skills/shannon/SKILL.md` |
| CLI reference | `skills/shannon/references/cli.md` |
| Agent roster reference | `skills/shannon/references/agents.md` |
| Pair reference | `skills/shannon/references/pair_work.md` |
| Handoff reference | `skills/shannon/references/handoff.md` |
| Fable session-pack reference | `skills/shannon/references/fable_handoffs.md` |
| FlexAIDdS campaign reference | `skills/shannon/references/flexaidds.md` |
