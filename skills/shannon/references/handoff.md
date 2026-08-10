# Resumable Claude Code / Dispatch handoff

Use this protocol when transferring current work, especially from a dirty
checkout or a multi-agent session. The handoff is a scientific receipt, not a
summary written from memory.

## 1. Freeze a stable snapshot

1. Stop local edits.
2. If workers are active, interrupt them and request a no-edit final receipt:
   changed files, incomplete hunks, tests actually run, failures, and next safe
   action.
3. Record live repository instructions, absolute checkout path, branch, HEAD,
   upstream relation, worktree status, and `git diff --check`.
4. Distinguish user-owned pre-existing changes from handoff-task changes. Never
   tell the receiver to reset, checkout, stash, or overwrite a dirty file.
5. Mark test evidence stale whenever any relevant edit happened after that test.

## 2. Plan without launching

A request to **prepare** a handoff does not authorize a live agent launch.
Generate a Shannon dry-run identity when useful:

```bash
PYTHONPATH="${SHANNON_ROOT:-.}/hub" python3 -m agent_manager pair \
  --pair-mode implement_only --task TASK_ID --summary "SUMMARY" \
  --dry-run --json
```

Use `claude_code` for direct implementation. Use `dispatch` only as a
coordinator: it should allocate explicit, disjoint file ownership and collect
receipts before integration. Do not create two writers for one shared file.

## 3. Write the artifact

Prefer the repository's existing handoff directory; otherwise use a clearly
named Markdown file. Include every section below:

1. **Mission and stop condition** — exact chunk/objective and what "done" means.
2. **Snapshot** — absolute path, branch, HEAD, upstream state, date, task ID.
3. **Authority boundary** — allowed edits/actions and actions requiring user
   approval.
4. **User-owned dirt** — exact files/directories and partial-staging warning.
5. **Implemented work** — by subsystem, without calling it verified unless it
   was tested after the last edit.
6. **Interrupted/incomplete work** — exact files and half-applied behavior.
7. **Remaining blockers** — severity-ranked, with file/function locations and
   concrete acceptance tests.
8. **Verification ledger** — command, result, and whether still current.
9. **Execution order** — chunked plan with one in-progress item and gates
   between chunks.
10. **Commit/push protocol** — repository-specific identity, staging, CI, and
    non-destructive git rules.
11. **Ready-to-paste prompt** — one for Claude Code; add a separate Dispatch
    prompt when requested.

Never include secrets, private keys, raw tokens, invented benchmark rates, or
claims unsupported by exact artifacts.

## 4. Receiver start protocol

Require the receiver to:

1. Read repository instructions and the handoff before editing.
2. Re-inspect live files; the handoff may be stale after transfer.
3. Run a cheap syntax/compile check on any interrupted file before continuing.
4. Preserve user-owned dirt and use partial staging where task/user hunks share
   a file.
5. Finish all listed blockers before claiming the chunk complete.
6. Run the repository's full relevant gates after the last edit, then inspect
   the staged diff before committing or pushing.

## 5. Dispatch ownership pattern

Give each worker an explicit lane such as C++ core, Python serialization,
Swift bridge/presentation, TypeScript viewer, or docs/validator. State: "You
are not alone in the codebase; do not revert others' edits." Keep integration
and shared-file staging with one coordinator. Require each worker to return:

- files changed;
- behavior changed;
- exact commands and pass/fail counts;
- unresolved blockers;
- confirmation that it did not commit.

The coordinator must independently inspect cross-language contracts and run the
combined gates. Package-local green tests are not evidence of producer-to-
consumer interoperability.
