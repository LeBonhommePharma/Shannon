# `agent_manager` CLI reference

> Part of the Shannon **SKILL** (`skills/shannon/SKILL.md`). Ground truth is
> `hub/agent_manager.py`; regenerate anything doubtful with `--help`.

```bash
export PYTHONPATH="${SHANNON_ROOT:-.}/hub${PYTHONPATH:+:$PYTHONPATH}"
python3 -m agent_manager --help
```

## Subcommands

| Command | Touches the gate? | Purpose |
|---------|-------------------|---------|
| `spawn` | live (or `--dry-run`) | Register agent, announce online |
| `control` | live | Send a control/status line |
| `kill` | live | Detach agent (hub offline status) |
| `monitor` | live — **registers you**, and currently hangs | List connected agents |
| `ask` | live | Request human approval via the pill |
| `result` | live | Send a gated result payload |
| `roster` | no | Print the 8 handrail identities |
| `gate-status` | probe only | Is the socket accepting? |
| `prefer-device` | no | Pick the least constrained device |
| `campaign` | **never** | Plan a FlexAIDdS campaign |
| `delegate` | **never** | Plan one role delegation |
| `pair` | **never** | Plan Claude Code ↔ Codex pair work |

`campaign`, `delegate`, `pair` and `prefer-device` are **pure planners**: output
is byte-identical with and without `--dry-run`. They emit a `spawn` plan; you
still have to run `spawn` to bring anything online.

## Common flags (accepted by every subcommand)

| Flag | Default | Notes |
|------|---------|-------|
| `--json` | off | Machine-readable output |
| `--mode socket\|http` | `socket` | See HTTP caveat below |
| `--socket PATH` | `/tmp/shannon.sock` | **No environment-variable override** — `agent_manager` reads no env at all |
| `--http-url URL` | `http://127.0.0.1:8765` | Needs `pip install requests` |

**HTTP mode is observation-only.** The gate scores and audits the message but
never marks the agent live (`hub/shannon_gate.py:3631`), so `monitor` will not
show an HTTP-mode agent as connected. `gate-status` **ignores `--mode`** and
always probes the Unix socket; for HTTP liveness use
`curl http://127.0.0.1:8765/state`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success — **including** an unknown `--pair-mode` (soft refusal) and an unknown `delegate` role |
| 1 | Live `Unknown agent_id` (raised client-side before connecting) |
| 2 | `gate-status`: gate down or socket stale |
| 3 | `campaign` / `delegate` dual-heavy-owner refusal (`refused: true`, `ok: false`) |
| 4 | `monitor`: the gate did not answer — roster **UNKNOWN**, not empty |
| 124 | Not ours — your `timeout` wrapper fired, almost always on `monitor` |

## What `--dry-run` does and does not do

It suppresses the gate call. It does **not** validate anything:

- Unknown agent id → planned cleanly, exit 0, synthesized ⚙️ identity.
- Empty agent id → `agent_id: ""`, exit 0.
- Unknown `delegate` role → `ok: true`, `agent_id` equal to the role slug.

Validate ids against the Canonical agent ids table, or against
`agent_identity.IDENTITIES` (17 entries) directly. On a canonical id the plan's
`label` carries that identity's own emoji; a generic ⚙️ means you typo'd.

## `campaign`

| Flag | Default |
|------|---------|
| `--campaign` | `red-pair` |
| `--task` | auto: `flexaidds_<campaign>_<epoch>_<hex8>` |
| `--owner` | `dataset_runner` |
| `--analysts` | `science` |
| `--coders` | *(none)* |
| `--coordinator` | `dispatch` |
| `--connected` | *(empty)* — synthetic roster for the dual-owner check |

**Always pass `--task`.** Omitting it mints a new id on every invocation, so a
re-plan after a spawn silently orphans the agents registered on the old id. The
generated shape is *not* the `flexaidds_redpair_YYYYMMDD` form older docs
showed.

Campaign slugs are normalized (`normalize_campaign_name`):

| Input | Canonical |
|-------|-----------|
| `red-pair`, `redpair`, `red_pair`, `three-engine`, `three_engine` | `red_pair` |
| `astex`, `astex85`, `astex_85` | `astex` |
| `hap2` | `hap2` |
| `casf`, `casf2016`, `casf_2016` | `casf` |

Anything else passes through with `-` → `_`.

Plan JSON keys: `action`, `campaign`, `task_id`, `phases` (always
`["A","B0","B"]`), `owner_agent_id`, `owner_role`, `delegations[]`, `refused`,
`refuse_reason`, `existing_heavy_owner`, `notes`, `ok`, `fabricated_entropy`,
`fabricated_cf`. The two `fabricated_*` fields are `null` by design — never
populate them.

### The dual-owner guard, precisely

The CLI never queries the hub. `--connected` is a roster **you** type in, and
the refusal fires only when a canonical member of `HEAVY_DOCKING_OWNER_IDS`
(currently just `dataset_runner`) appears in it.

```bash
# exit 3, refused ✅
python3 -m agent_manager campaign --connected dataset_runner --dry-run --json
# exit 3, refused ✅  (aliases and case/space/hyphen variants all normalize)
python3 -m agent_manager campaign --connected dr --dry-run --json
python3 -m agent_manager campaign --connected "Dataset Runner" --dry-run --json
# exit 0, refused:false ❌ — Display string, not an id
python3 -m agent_manager campaign --connected DatasetRunner --dry-run --json
# exit 0, refused:false — no roster was supplied
python3 -m agent_manager campaign --dry-run --json
```

`--owner <anything but dataset_runner>` disables the refusal outright while
still labelling the delegation `docking_owner`.

## `delegate`

Positional `role`, plus `--task` (required), `--agent` (override the resolved
id), `--connected`. Roles come from `CAMPAIGN_ROLE_DEFAULTS`, and are
case/space/hyphen-insensitive:

| Role token(s) | Resolves to |
|---|---|
| `docking_owner`, `owner`, `dataset_runner` | `dataset_runner` (heavy — guarded) |
| `science_analyst`, `analyst`, `science` | `science` |
| `code_claude`, `claude_code` | `claude_code` |
| `code_codex`, `codex` | `codex` |
| `code_grok`, `grok_build` | `grok_build` |
| `coordinator`, `dispatch` | `dispatch` |
| `design`, `cowork`, `opencode` | themselves |

**Unknown roles are not rejected** — `delegate typo_science` returns `ok: true`
with `agent_id: "typo_science"`. Check the echoed `agent_id`.

Delegation JSON keys: `action`, `role`, `agent_id`, `task_id`, `refused`, `ok`,
`refuse_reason`, `existing_heavy_owner`, `plan`.

## `result`

`--payload` takes a JSON object, or `-` to read it from stdin (use that for
payloads too large or quote-heavy for a shell argument).

`--confidence` defaults to **0.9** and is merged into the gated payload as
`confidence`. An unqualified `result` therefore self-reports high confidence —
set it honestly.

## `monitor`

Returns `connected` (list of agent ids), `roster_known` (bool), `recent`,
`report`, `ok`, and — when the gate did not answer — `error`.

**Branch on `roster_known`, never on `connected` alone.** `connected: []` with
`roster_known: true` means the hub really is idle; `connected: []` with
`roster_known: false` (exit 4) means the gate stayed silent and you know
nothing. Only the first is safe to feed to `--connected`.

The gate nests the roster under `data`; the manager unwraps it and also accepts
a flat reply, so both socket and any unwrapping transport work.

With no flags `monitor` registers *as `dispatch`*, displacing a real Dispatch
connection — always pass `--agent <your id> --task <your task id>`. Keep it
under `timeout` as well: a transport that does not bound its wait for a reply
can still wedge, and exit 124 carries the same meaning as exit 4.

## `prefer-device`

Pure planner. Pass the device list **inline**:

```bash
python3 -m agent_manager prefer-device \
  --devices '[{"device_id":"mac1","cpu_percent":10},{"device_id":"mac2","cpu_percent":90}]' \
  --busy-threshold 85 --json
```

`--devices -` reads the array from stdin. Inline is the form that works on
every tree, and a bare `prefer-device` with nothing on stdin is an error
(`{"ok": false, …}`), not an empty result. **Check the `ok` field**, not just
the exit status — this subcommand has historically returned failures with
exit 0.

## Gate message types that are not CLI subcommands

`benchmark_update` and `code_suggestion` are gate message types, not commands —
`python3 -m agent_manager code_suggestion` fails with `invalid choice`. Send
them inside a `result` payload, or use the Python client directly
(`hub/agent_protocol.py`: `send_code_suggestion`, `send_benchmark_update`).

The FlexAIDdS side has its own bridge, which posts `benchmark_state` rows on
behalf of `dataset_runner`:

```bash
python3 hub/tools/dataset_runner_bridge.py \
  --results-dir <dir> --task "$TASK_ID" --total 85 --once --json
```

Without `--once` it watches the directory on `--interval` (default 2 s).
