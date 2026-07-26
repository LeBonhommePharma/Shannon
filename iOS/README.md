# Shannon for iPhone (iOS)

Live companion for the **Mac Shannon hub**: agent cards, confirmations, Now Playing
transport that reaches back to the Mac, a Lock/Home Screen widget, and AirPods
gestures. This is **not** a standalone agent runtime — the Mac owns gate/pets/compute.

| Item | Value |
|------|--------|
| **Min OS** | iOS **17.0** (Observation, scroll targets, modern widget APIs) |
| **Bundle prefix** | `com.lebonhommepharma.shannon` |
| **Paired watch** | Schemes live in the same XcodeGen project (see [watchOS/README.md](../watchOS/README.md)) |
| **Shared packages** | `Packages/ShannonCore`, `Packages/ShannonTheme` |

## What the phone does

- **Agent cards** — status, task line, turns, entropy H when the Mac publishes it
- **Confirm / Deny** — nod/shake (AirPods), stem presses, buttons, voice (on-device only)
- **Now Playing** — controls emit `RemoteCommand` records for the Mac (not local media)
- **Widget** — Lock / Home Screen glance via App Group
- **Empty backend** — without CloudKit entitlements the app launches and shows empty state (honest, not a crash)

What it does **not** do: run `shannon-agent`, write `~/.shannon/pets`, or compute collapse detection locally.

## Build

```bash
# From repo root
cd iOS
xcodegen generate                 # writes Shannon.xcodeproj from project.yml
open Shannon.xcodeproj            # set Team if deploying to a device
```

Simulator (unsigned):

```bash
cd iOS
xcodegen generate
xcodebuild -project Shannon.xcodeproj -scheme ShannonPhone \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

**Environment limit:** some Xcode beta hosts hang `simctl` or lack SimulatorKit —
if so, `CODE_SIGNING_ALLOWED=NO` compile still proves the target builds; runtime
screenshots may be unavailable. Record that honestly; do not invent UI proof.

## Tests (pure logic — run on Mac)

iPhone UI is not unit-tested in CI. Shared behaviour lives in ShannonCore:

```bash
cd Packages/ShannonCore && swift test
# Focus areas: ConfirmationAndVoiceTests, SyncBehaviourTests, SecurityTests,
# GlobalNotifyResponseTests, HostCapacityCompanionPresenceTests
```

Theme tokens:

```bash
cd Packages/ShannonTheme && swift test
```

## Sync & signing

Activation steps (iCloud container, App Groups, Keychain, Push) are documented once in
[`docs/MULTI_DEVICE.md`](../docs/MULTI_DEVICE.md). Container id:

```
iCloud.com.lebonhommepharma.shannon
```

Without a Developer team, leave `DEVELOPMENT_TEAM` blank in `project.yml` — Simulator
builds still work.

## Layout (sources)

```
iOS/
  project.yml                 # XcodeGen: Phone + Widget + Watch + Complication
  Sources/ShannonPhone/       # SwiftUI app
  Sources/ShannonWidget/      # WidgetKit
  Sources/Shared/             # shared with watch targets where applicable
  Resources/PrivacyInfo.xcprivacy
```

## Related

- Multi-device architecture: [`docs/MULTI_DEVICE.md`](../docs/MULTI_DEVICE.md)
- Mac hub: [`Pill/README.md`](../Pill/README.md)
- Root operator path: [`README.md`](../README.md)
