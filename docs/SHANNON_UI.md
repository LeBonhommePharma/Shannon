# Shannon UI lives in a separate repo

**Shannon UI** (Apple / Swift surfaces: Pill macOS HUD, iOS, iPad, watchOS,
ShannonCore, ShannonTheme, fastlane) was extracted to:

**https://github.com/LeBonhommePharma/ShannonUI**

History for those paths was preserved via `git filter-repo`.

This monorepo is **Shannon CLI** + science: C++/Python entropy core, hub gate,
agent tooling, installers, and docs. The two products share operator handrails
(`./scripts/shannon`) but are not one mixed binary.

| Product | Repo | Role |
|---------|------|------|
| **Shannon UI** | [ShannonUI](https://github.com/LeBonhommePharma/ShannonUI) | Sole shipped menu-bar / notch HUD (+ companions) |
| **Shannon CLI** | this repo | Headless entropy monitor, gate, agent manager, C++ `shannon-agent` |

## What stayed here

- `src/` — C++ entropy core
- `python/`, `hub/` — Python package + multi-agent gate (Shannon CLI)
- `examples/`, `tools/`, `skills/`, `benchmarks/`, `data/`, `docker/`, `docs/`
- Homebrew `Formula/` (Shannon CLI) + `Casks/` (Shannon UI packaging metadata)
- Agent/tooling: `.grok/`, `.claude/`, `.agents/`, `.github/`
- Build: `CMakeLists.txt`, `pyproject.toml`, `setup.py`, `scripts/`

## What moved

| Path | Destination |
|------|-------------|
| `Pill/` | ShannonUI |
| `iOS/` | ShannonUI |
| `iPad/` | ShannonUI |
| `watchOS/` | ShannonUI |
| `Packages/` | ShannonUI |
| `fastlane/` | ShannonUI |

## Operator routing

```bash
# Shannon CLI (this clone) — always headless-safe
./scripts/shannon help
./scripts/shannon status
shannon-monitor --help

# Shannon UI rebuild — needs a ShannonUI checkout (or cask install)
git clone https://github.com/LeBonhommePharma/ShannonUI ../ShannonUI
./scripts/shannon app
# override: export SHANNON_UI_ROOT=/path/to/ShannonUI
```

Legacy dual status-item Swift UI (`AgentHubApp`) is archived under
`archive/legacy_agent_hub_ui/` and is **not** part of either production product.

Clone both repos if you work on the full product stack.
