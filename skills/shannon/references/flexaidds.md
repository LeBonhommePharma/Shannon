# FlexAIDdS + Shannon concurrent benchmarking

**Shannon owns the campaign.** Agents do not invent a parallel orchestration
workflow. All lifecycle traffic goes through the Shannon skill / hub CLI
(`spawn` / `control` / `monitor` / `ask` / `result` / `kill` / `campaign` /
`delegate`).

Commands and flags live in `SKILL.md` § CLI and `references/cli.md`. This file
adds only the FlexAIDdS-specific role map and protocol.

## Ownership

| Role | Agent id | `delegate` token | Responsibility |
|------|----------|------------------|----------------|
| **Campaign owner (Shannon)** | — | — | Plans phases A→B0→B, assigns roles, refuses dual heavy owners |
| Docking engine bridge | `dataset_runner` | `docking_owner` | Sole heavy-arm owner. This is a Shannon **registration identity** for whichever process owns the live heavy arm — classic FlexAID A/B0/B *or* the FlexAIDdS C0/C DatasetRunner packaging path. Do not confuse it with the C++ DatasetRunner class. |
| Science analysis | `science` | `science_analyst` | tENCoM / entropy / CF disagreement notes (not docking launch) |
| Code changes | `claude_code`, `codex`, `grok_build`, `opencode` | `code_claude`, `code_codex`, `code_grok`, `opencode` | patches via `code_suggestion` + LP approval |
| Coordination | `dispatch` | `coordinator` | fan-out, monitor, kill stuck workers |
| Design / UX | `design` | `design` | UI specs only — no docking launch |
| Cowork | `cowork` | `cowork` | shared doc / handoff |

> `code_suggestion` and `benchmark_update` are **gate message types, not CLI
> subcommands** — `python3 -m agent_manager code_suggestion` fails with
> `invalid choice`. Send them inside a `result` payload, or use
> `hub/agent_protocol.py` (`send_code_suggestion`, `send_benchmark_update`).
> For result ingestion there is a dedicated bridge,
> `hub/tools/dataset_runner_bridge.py` — see `cli.md`.

## Protocol

1. **Shannon plans the campaign** — `campaign --task "$TASK_ID" --dry-run --json`.
   Inspect `owner_agent_id`, `delegations[]`, `phases`. Always pass `--task`, or
   each re-plan mints a new id and orphans agents spawned on the old one.

2. **Establish who is online.**

   ```bash
   timeout 20 python3 -m agent_manager monitor --agent <your_id> --task "$TASK_ID" --json
   ```

   > **WARNING — live `monitor` can hang forever.** The client sets no read
   > timeout (`hub/agent_protocol.py:405`), so a gate that accepts the connection
   > but never answers blocks the CLI indefinitely while `gate-status` still
   > reports `gate_up: true`. Exit **124** means it hung. `monitor --dry-run` is
   > **not** a fallback — it returns the query plan, not a roster.
   >
   > Also: a bare `monitor` registers **as `dispatch`** and displaces a live
   > Dispatch connection. Always pass `--agent <your own id>`.

3. **If you have no roster, you cannot satisfy the dual-owner rule.** Assume a
   heavy owner may be online, do not plan or spawn a second one, and ask the
   human via the pill.

4. **Re-plan with what you saw.** The dual-owner check is driven by a
   **synthetic** roster you supply — it is never a hub query:

   ```bash
   python3 -m agent_manager campaign --connected dataset_runner --dry-run --json   # exit 3
   ```

   A bare plan returns `refused: false` even while an owner is live. Pass
   canonical ids (`dataset_runner` / `dr` / `dataset`) — the Display string
   `DatasetRunner` silently passes the guard.

5. `spawn <delegated_agent> --task "$TASK_ID"` for each role Shannon assigned.
6. `control` phase lines: `A started`, `B0 packing`, `PoseBusters…`
7. `dataset_runner` emits `result` / benchmark updates with cf/rmsd (never invent).
8. Analysts emit `result` with analysis text — the gate scores entropy. Set
   `--confidence` honestly; it defaults to 0.9.
9. Risky code: `ask` (CLI) or a `code_suggestion` gate message via
   `agent_protocol.py` — never silent merge.
10. `kill` on exit for every delegated agent.

## Hard bans

**Shannon's own:** no dual `dataset_runner` (or other heavy owner) for the same
campaign.

**Inherited from the sibling `flexaidds-benchmarking` skill**
(`$FLEXAIDDS_ROOT/.agents/skills/flexaidds-benchmarking/SKILL.md` → "Hard bans
(misgiving prevention)", `FLEXAIDDS_ROOT` defaulting to `~/Projects/FlexAIDdS`).
It has **7 rows — read them all before touching an arm**; this summary is not a
substitute:

- Serial **one** heavy arm at a time (A→B0→B) — never dual-launch A with B0/B/C0 on one Mac
- **SHARESCL 10** / SHAREPEK 5 in `ga.inp` — never reintroduce SHARESCL 0.20 (pilot typo)
- Softβ DatasetRunner election **OFF** by default — no claim that Softβ fixes BCR=0
- Call arm B **FO@TEMPER21**, not "Softβ S1 rescoring of CF ensembles"
- Fail-closed ligand integrity + native CF oracle
- Local-first OUT/work for classic arms — no live GA traffic to hanging iCloud paths
- Rebuild the binary after the `read_lig` latm fix

Pin the `flexaidds-benchmarking` skill for science detail; the Shannon skill
owns **campaign orchestration + agent lifecycle** only.
