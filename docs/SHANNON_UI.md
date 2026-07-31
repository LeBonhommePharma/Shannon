# Shannon UI lives in a separate repo

The Apple / Swift surfaces (Pill macOS HUD, iOS, iPad, watchOS, ShannonCore,
ShannonTheme, fastlane) were extracted to:

**https://github.com/LeBonhommePharma/ShannonUI**

History for those paths was preserved via `git filter-repo`.

## What stayed here

- `src/` — C++ entropy core
- `python/`, `hub/` — Python package + multi-agent gate
- `examples/`, `tools/`, `skills/`, `benchmarks/`, `data/`, `docker/`, `docs/`
- Homebrew `Formula/` + `Casks/`
- Agent/tooling: `.grok/`, `.claude/`, `.agents/`, `.github/`
- Build: `CMakeLists.txt`, `pyproject.toml`, `setup.py`, `scripts/` (installers, swarm, etc.)

## What moved

| Path | Destination |
|------|-------------|
| `Pill/` | ShannonUI |
| `iOS/` | ShannonUI |
| `iPad/` | ShannonUI |
| `watchOS/` | ShannonUI |
| `Packages/` | ShannonUI |
| `fastlane/` | ShannonUI |

Clone both if you work on the full product stack.
