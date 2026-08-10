# Shannon handrail agent roster

Canonical ids live in `hub/agent_identity.py`, in three nested tiers:

| Tier | Count | What it is |
|------|-------|------------|
| `CORE_AGENT_IDS` | 6 | grok_build, codex, claude_code, dispatch, cowork, science — surface as `"core": true` in `roster --json` |
| `HANDRAIL_AGENT_IDS` | 8 | core + design + opencode — **exactly what `agent_manager roster` prints** |
| `IDENTITIES` | 17 | every id the gate accepts (`agent_protocol.VALID_AGENTS` is the same set) |

An id being absent from `roster` does **not** make it invalid. Most importantly,
`dataset_runner` — the heavy docking owner that every campaign example uses — is
a real identity that `roster` never prints.

## Handrail (the 8 `roster` returns)

| Id | Display | Auth | Pet | Host TUIs |
|----|---------|------|-----|-----------|
| grok_build | Grok Build | cloud | raven | Grok Build, xAI |
| codex | Codex | cloud | dolphin | OpenAI Codex CLI/IDE |
| claude_code | Claude Code | local | fox | Claude Code |
| science | Claude Science | local | owl | Claude Science / Fable |
| cowork | Cowork | local | beaver | Claude Cowork |
| dispatch | Dispatch | local | wolf | Claude Dispatch |
| design | Claude Design | local | peacock | Claude Design app / design CLI / artifacts canvas |
| opencode | OpenCode | local | octopus | OpenCode TUI |

## Extended (valid on the wire, never returned by `roster`)

chatgpt, dataset_runner, local_test, terminal, browser, cursor, vscode, xcode, kimi

Regenerate this list rather than trusting it:

```bash
python3 -c "import sys;sys.path.insert(0,'hub');import agent_identity as a;print(sorted(a.IDENTITIES))"
```

## Aliases (`agent_manager.normalize_agent_id`)

Input is normalized before lookup: trimmed, lower-cased, spaces and hyphens →
underscores. So `Dataset Runner`, `DATASET_RUNNER` and `dataset-runner` all
resolve, but the concatenated Display form **`DatasetRunner` does not** — it
becomes `datasetrunner`, matches no alias, and is passed through unchanged.
That is what silently defeats the `--connected` dual-owner guard.

| Aliases | Canonical |
|---------|-----------|
| grok, grokbuild, xai | grok_build |
| claude, cc, claudecode | claude_code |
| sci, claude_science, claudescience | science |
| claude_cowork, claudecowork | cowork |
| claude_dispatch, claudedispatch | dispatch |
| openai_codex | codex |
| claude_design, claudedesign, des | design |
| oc, open_code | opencode |
| dr, dataset | dataset_runner |

Unrecognised slugs are returned **unchanged**, not rejected — see the
`--dry-run` caveat in `cli.md`.

## Picking your own id

By **host process, not by task**: a Claude Code CLI session is `claude_code`
even when doing science work. `science` is reserved for Claude Science / Fable
sessions, and only one live `science` registration may exist at a time (see
`fable_handoffs.md`).
