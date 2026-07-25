# FlexAIDdS + Shannon concurrent benchmarking

Shannon hub coordinates **who is working which arm** so multiple agents do not
dual-launch heavy docking on one Mac.

## Ownership

| Role | Agent id | Responsibility |
|------|----------|----------------|
| Docking engine bridge | `dataset_runner` | `benchmark_update`, file watcher results |
| Science analysis | `science` | tENCoM / entropy / CF disagreement notes |
| Code changes | `claude_code`, `codex`, `grok_build`, `opencode` | patches via `code_suggestion` + LP approval |
| Coordination | `dispatch` | fan-out, monitor, kill stuck workers |
| Design / UX | `design` | UI specs only — no docking launch |
| Cowork | `cowork` | shared doc / handoff |

## Protocol

1. `python3 -m agent_manager monitor` — who is online?
2. If another agent owns a heavy arm, **do not spawn a second owner**.
3. `spawn <you> --task flexaidds_<campaign>_<date>`
4. `control` phase lines: `A started`, `B0 packing`, `PoseBusters…`
5. `dataset_runner` emits `benchmark_update` / `result` with cf/rmsd.
6. Analysts emit `result` with analysis text — gate scores entropy.
7. Risky code: `ask` or `code_suggestion` — never silent merge.
8. `kill` on exit.

## Hard bans (from FlexAIDdS skill)

- Serial **one** heavy arm at a time (A→B0→B)
- No Softβ claims that fix BCR=0
- Local-first OUT/work for classic arms

Pin FlexAIDdS skill for science detail; Shannon skill only owns **agent lifecycle**.
