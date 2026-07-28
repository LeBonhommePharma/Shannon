# Apple platform testing (macOS · iOS · iPadOS · watchOS)

Agent- and human-facing guide for exercising **all** Shannon Apple surfaces
when the host allows it. Failures and skips are reported honestly — never invent
simulator UI proof.

## One command

From repo root (macOS + Xcode):

```bash
# Prove generated .xcodeproj files are loadable (clean generate, no GUI).
# Run this before opening projects in Xcode / Xcode-beta — especially on
# macOS 27 + Xcode 27 beta — so a stale package cannot hang first-load.
./scripts/validate_xcodeprojs.sh

# Multi-platform build/test health
./scripts/test_apple_platforms.sh

# Coordinated swarm (packages + Pill + Python + iCloud focus + installer + mobile)
./scripts/platform_swarm.sh
./scripts/platform_swarm.sh --quick          # faster Pill (build only)
./scripts/platform_swarm.sh --sync-only      # ShannonCore CloudKit codecs / security
./scripts/platform_swarm.sh --installer      # pure-Python install/update re-verify
# Optional: per-lane logs (parallel core/theme/pill/python + sequential run_lane steps)
# SHANNON_SWARM_LOG_DIR=/path/to/logs ./scripts/platform_swarm.sh --quick
```

### Multi-OS fan-out (who runs what)

| Layer | Entry | Parallelism |
|---|---|---|
| **Desktop OS matrix** | GitHub Actions `ci.yml` (`cpp` / `python` / …) | Concurrent jobs, `fail-fast: false` (Ubuntu / macOS / Windows Python) |
| **Local Mac swarm** | `./scripts/platform_swarm.sh` | True-parallel Core + Theme + Pill + Python; then sequential Apple + installer |
| **Apple surfaces** | `./scripts/test_apple_platforms.sh` | Sequential macOS → iOS → iPad → watch (Xcode-heavy); honest **SKIP** when no sim |

Do **not** invent a second harness that duplicates these. Windows C++ core is intentionally not in CI (pure-Python path only).

| Flag / args | Meaning |
|---|---|
| *(none)* | macOS packages + Pill tests, then iOS / iPad / watch builds when possible |
| `macos` `ios` `ipad` `watch` | Subset only |
| `--quick` | Skip full Pill test suite (build + packages only) |
| `--list` | Print Xcode version, runtimes, sim devices |

Exit **0** if every *runnable* step succeeded. **SKIP** does not fail the run.
Exit **1** if a selected step that actually ran failed.

Optional: `SHANNON_XCODE_TIMEOUT=900` (seconds) caps each xcodebuild/swift step
when `timeout`/`gtimeout` is on `PATH`.

### Xcode project hygiene (local + Xcode-beta)

`.xcodeproj` trees are **generated** (gitignored) from `project.yml` via
XcodeGen. They are **not** checked in.

| Project | Spec | Open after validate |
|---|---|---|
| `Pill/ShannonPill.xcodeproj` | `Pill/project.yml` | `open Pill/ShannonPill.xcodeproj` |
| `iOS/Shannon.xcodeproj` | `iOS/project.yml` | `open iOS/Shannon.xcodeproj` |
| `iPad/ShannonPad.xcodeproj` | `iPad/project.yml` | `open iPad/ShannonPad.xcodeproj` |

**Always clean-regenerate** (delete the whole `.xcodeproj`, then `xcodegen
generate`). XcodeGen rewrites `project.pbxproj` but leaves extra directories
already inside the package. A clang module cache once landed as
`iOS/Shannon.xcodeproj/-Xcc/` (~30 MB of `.pcm`); opening that in Xcode-beta
can hang indexing or make first-load look broken.

```bash
# Preferred — wipe + generate + xcodebuild -list / -showBuildSettings
./scripts/validate_xcodeprojs.sh

# Opt-in GUI open only after the above is green
./scripts/validate_xcodeprojs.sh --open
```

`setup.sh` and `test_apple_platforms.sh` both wipe before generate. Do **not**
point `MODULE_CACHE_PATH` / clang caches at a path inside any `.xcodeproj`.

## What runs where

| Platform | Product | How this script verifies |
|---|---|---|
| **macOS** | Pill + `ShannonCore` / `ShannonTheme` | `swift test` / `swift build` (full logic suite) |
| **iOS** | `ShannonPhone` (+ widget embed) | `xcodegen` + unsigned `xcodebuild` to iOS Simulator (device or generic) + Core for iOS Simulator SDK |
| **iPadOS** | `ShannonPad` | Same pattern as iOS with iPad sim when available |
| **watchOS** | `ShannonWatch` (scheme in `iOS/Shannon.xcodeproj`) | Unsigned build to watchOS Simulator + Core for watch SDK |

There are **no separate XCTest targets** for Phone/Pad/Watch UI in CI yet.
Behaviour is covered by:

- **ShannonCore** pure tests (confirmations, voice, sync, security, …)
- **Unsigned Simulator compiles** of the app targets (prove they still build)

## Prerequisites

| Tool | Required for |
|---|---|
| Xcode (CLI: `xcodebuild`) | All platforms |
| `xcodegen` (`brew install xcodegen`) | iOS / iPad / watch app projects |
| Simulator **runtimes** | Device creation (Settings → Platforms / Xcode → Settings) |
| Simulator **devices** | Optional — script creates `Shannon-*-Agent` devices when runtime + type exist |

Without a signed Developer team, builds use `CODE_SIGNING_ALLOWED=NO` (Simulator
only). See `docs/MULTI_DEVICE.md` for CloudKit / device deploy.

## Manual equivalents

```bash
# Shared model (any Mac)
cd Packages/ShannonCore && swift test
cd Packages/ShannonTheme && swift test
cd Pill && swift build && swift test

# Clean generate (rm first — never accumulate junk inside .xcodeproj)
rm -rf iOS/Shannon.xcodeproj && cd iOS && xcodegen generate && cd ..
rm -rf iPad/ShannonPad.xcodeproj && cd iPad && xcodegen generate && cd ..
rm -rf Pill/ShannonPill.xcodeproj && cd Pill && xcodegen generate && cd ..

# iPhone
xcodebuild -project iOS/Shannon.xcodeproj -scheme ShannonPhone \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# iPad
xcodebuild -project iPad/ShannonPad.xcodeproj -scheme ShannonPad \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Watch (scheme is in the iOS project)
xcodebuild -project iOS/Shannon.xcodeproj -scheme ShannonWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Agent loop protocol

The 10‑minute Shannon loop should:

1. Prefer `./scripts/test_apple_platforms.sh --quick` when the change is
   multi-surface (core sync, voice, confirmations, theme).
2. Use full `./scripts/test_apple_platforms.sh` after larger companion edits.
3. On **SKIP** (no sim runtime, no xcodegen): record the reason in the loop
   summary; still require **macOS** `swift test` green for logic changes.
4. Append backlog items when a platform build regresses or a new gap is found
   (`docs/ENHANCEMENT_BACKLOG.md` ENH-018+, or pet backlog).

## CI note

Hosted runners may lack full Simulator runtimes. Generic destinations or
macOS-only jobs are acceptable. Local agents with Xcode should run the full
script when possible.

## Related

- [iOS/README.md](../iOS/README.md) · [iPad/README.md](../iPad/README.md) · [watchOS/README.md](../watchOS/README.md)
- [Pill/README.md](../Pill/README.md) · [docs/MULTI_DEVICE.md](MULTI_DEVICE.md)
