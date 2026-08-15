# Shannon UI lives in a separate repo

**Shannon UI** (Apple / Swift surfaces: Pill macOS HUD, iOS, iPad, watchOS,
ShannonCore, ShannonTheme, fastlane) was extracted to:

**https://github.com/LeBonhommePharma/ShannonUI** (private)

History for those paths was preserved via `git filter-repo`.

This monorepo is **Shannon CLI** + science: C++/Python entropy core, hub gate,
agent tooling, installers, and docs. The two products share operator handrails
(`./scripts/shannon`) but are not one mixed binary.

| Product | Repo | Role |
|---------|------|------|
| **Shannon UI** | [ShannonUI](https://github.com/LeBonhommePharma/ShannonUI) (**private**) | Sole shipped menu-bar / notch HUD (+ companions) |
| **Shannon CLI** | this repo | Headless entropy monitor, gate, agent manager, C++ `shannon-agent` |

## Private clone (required)

ShannonUI is **private**. Anonymous `git clone https://…` and the default
GitHub Actions `GITHUB_TOKEN` **cannot** fetch it. Use one of:

```bash
# SSH (recommended when your GitHub account has access)
git clone git@github.com:LeBonhommePharma/ShannonUI.git ../ShannonUI

# HTTPS via GitHub CLI (uses your logged-in credentials)
gh auth login   # once
gh repo clone LeBonhommePharma/ShannonUI ../ShannonUI

# HTTPS with a personal access token (PAT) that can read ShannonUI
git clone "https://x-access-token:${SHANNON_UI_CHECKOUT_TOKEN}@github.com/LeBonhommePharma/ShannonUI.git" ../ShannonUI
```

Then point the CLI handrail at the checkout:

```bash
export SHANNON_UI_ROOT=../ShannonUI   # optional; sibling path is auto-detected
./scripts/shannon app
./scripts/package_pill.sh --install
./scripts/test_apple_platforms.sh --quick
```

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
./scripts/shannon grok --dry-run
shannon-monitor --help

# Shannon UI rebuild — needs an authenticated ShannonUI checkout
git clone git@github.com:LeBonhommePharma/ShannonUI.git ../ShannonUI
./scripts/shannon app
./scripts/package_pill.sh --install   # same resolve (lib_shannon_ui.sh)
./scripts/test_apple_platforms.sh --quick   # SKIP if UI missing; run if present
```

Shared resolve helper: `scripts/lib_shannon_ui.sh` (`resolve_shannon_ui`,
`SHANNON_UI_ROOT`, `PILL_DIR`). Packaging, swarm, and apple-platform scripts
all source it.

## CI / release (GitHub Actions)

| Workflow | Behavior without secret | Behavior with secret |
|----------|-------------------------|----------------------|
| `ci.yml` → `apple-platforms` | Checkout fails → **SKIP** Apple lanes (exit 0) | Checkout ShannonUI → real Pill/Core/Theme lanes |
| `release.yml` → `build-macos-app` | **Fails** (secret required) | Checkout ShannonUI → package DMG/ZIP/cask |

**Repository secret (this Shannon CLI repo):**

| Name | Purpose |
|------|---------|
| `SHANNON_UI_CHECKOUT_TOKEN` | PAT or fine-grained token with **read** access to `LeBonhommePharma/ShannonUI` |

Create a classic PAT with `repo` scope (or a fine-grained token limited to
ShannonUI contents:read), then:

```bash
# as a repo admin on LeBonhommePharma/Shannon
gh secret set SHANNON_UI_CHECKOUT_TOKEN --repo LeBonhommePharma/Shannon
# paste the PAT when prompted
```

Workflows wire it as:

```yaml
token: ${{ secrets.SHANNON_UI_CHECKOUT_TOKEN }}
```

on the ShannonUI `actions/checkout` step. Do **not** rely on
`${{ github.token }}` for the private sibling.

Legacy dual status-item Swift UI (`AgentHubApp`) is archived under
`archive/legacy_agent_hub_ui/` and is **not** part of either production product.

Clone both repos (with auth) if you work on the full product stack.
