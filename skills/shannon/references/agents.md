# Shannon handrail agent roster

Canonical ids live in `hub/agent_identity.py` (`HANDRAIL_AGENT_IDS` + `IDENTITIES`).

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

## Aliases (`agent_manager.normalize_agent_id`)

- grok, grokbuild, xai → grok_build
- claude, cc, claudecode → claude_code
- sci, claude_science → science
- claude_cowork → cowork
- claude_dispatch → dispatch
- design, claude_design, claudedesign, des → design
- oc, open_code → opencode
- dr, dataset → dataset_runner

## Extended (valid, not always in handrail UI)

chatgpt, dataset_runner, local_test, terminal, browser, cursor, vscode
