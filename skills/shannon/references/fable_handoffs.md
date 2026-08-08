# Claude Science/Fable session packs

Use this protocol to split one resumable task across multiple Fable sessions
without creating competing scientific truths or interfering with live
experiments.

## Non-interference first

- Treat existing Claude Science/Fable and DatasetRunner experiments as
  untouchable external work.
- Do not spawn, control, kill, detach, reuse, or replace their Shannon agent
  identities or task IDs.
- Do not launch a live multi-session pack while `science` or `dataset_runner`
  is active. If monitor state is unavailable or ambiguous, prepare prompts and
  dry-run receipts only.
- Do not launch benchmarks, docking, tENCoM/Eigen, parity, determinism, or other
  heavy campaigns from a code-remediation session pack.
- Defer heavy builds/tests when they could contend with an experiment for CPU,
  memory, disk, or I/O. Never use broad process-kill or cleanup commands.

The canonical Shannon identity `science` represents one live agent. Multiple
Fable UI sessions are labels in a handoff pack, not multiple simultaneous live
`science` registrations. Register them sequentially only after existing
experiments end, or let Dispatch coordinate them outside the live gate while
preserving the same receipts.

## Contract-first dependency graph

Use a directed dependency graph, not an undifferentiated parallel swarm:

1. **Truth session**: establish and test the canonical contract.
2. **Mirror sessions**: start only after the truth receipt is available; each
   owns disjoint adapters/consumers and may not redefine the contract.
3. **Integration session**: start after all mirrors return receipts; inspect
   cross-language parity, combined tests, staging, and handoff completion.

For FlexAIDdS statistical mechanics, C++ (`LIB/statmech.h/.cpp` plus C++ tests)
is the scientific source of truth unless the user explicitly selects another
authority. Cross-language convenience must never weaken C++ predicates,
vocabulary, units, reference-state requirements, or numeric invariants. Change
the C++ contract first, test it, then regenerate/consume language-neutral golden
fixtures.

## Session prompt contract

Give every session:

- the master handoff path and immutable snapshot/checksums;
- its prerequisite receipt(s);
- exact owned files/directories and forbidden paths;
- the canonical truth files it must read but not edit;
- explicit numeric/noninterference invariants;
- focused tests it may run without resource contention;
- a stop condition and receipt schema;
- the statement: "You are not alone in the codebase; do not revert, stage,
  commit, or overwrite another session's work."

Each receipt must report:

```text
session_id:
truth_receipt_consumed:
files_changed:
contract_observed:
numeric_behavior_changed: yes/no + evidence
tests_run: exact commands and counts
tests_deferred_for_experiment_safety:
unresolved_blockers:
out_of_lane_files_touched: none/list
commit_created: no
```

## Five-session pattern

A safe five-session FlexAIDdS split is:

1. C++ truth and native tests.
2. Python mirror and serialization/PDB loaders.
3. TypeScript mirror and viewer wire/presentation gates.
4. Swift mirror and bridge/intelligence gates.
5. Docs/validator/CI integration and combined read-only review.

Run Session 1 first. Sessions 2–4 may proceed after its receipt because their
write ownership is disjoint. Run Session 5 last. Keep commit/push ownership with
one integration coordinator, not the individual sessions.
