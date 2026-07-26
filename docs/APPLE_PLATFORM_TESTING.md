# Apple platform testing (macOS · iOS · iPadOS · watchOS)

Agent- and human-facing guide for exercising **all** Shannon Apple surfaces
when the host allows it. Failures and skips are reported honestly — never invent
simulator UI proof.

## One command

From repo root (macOS + Xcode):

```bash
./scripts/test_apple_platforms.sh
```

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

# iPhone
cd iOS && xcodegen generate
xcodebuild -project Shannon.xcodeproj -scheme ShannonPhone \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# iPad
cd iPad && xcodegen generate
xcodebuild -project ShannonPad.xcodeproj -scheme ShannonPad \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Watch (scheme is in the iOS project)
cd iOS && xcodegen generate
xcodebuild -project Shannon.xcodeproj -scheme ShannonWatch \
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
