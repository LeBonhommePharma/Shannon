# Shannon for Apple Watch (watchOS)

Display-and-gesture companion only. The watch **never** runs entropy kernels or
docks targets; it receives the latest snapshot via **WatchConnectivity** from the
iPhone and shows the **Shannon Face**, complications, and confirmation UI.

| Item | Value |
|------|--------|
| **Min OS** | watchOS **10.0** (Double Tap / Smart Stack / modern complications) |
| **Xcode project** | Generated with the iPhone app — `cd iOS && xcodegen generate` |
| **Schemes** | `ShannonWatch`, `ShannonComplication` |
| **Shared model** | `Packages/ShannonCore` (watchOS 9+ library floor) |

## What the watch does

- **Shannon Face** — large time, active agent line, Now Playing glance, Always-On dim path
- **Complications** — families + Smart Stack via `ShannonWatchComplication`
- **Crown** — navigate face / agents / Now Playing / alerts (haptic detents where implemented)
- **Double Tap** (Series 9+) — confirm primary action / play-pause on NP screen
- **Voice** — system dictation sheet with short confirm/deny/status suggestions

What it does **not** do: open CloudKit, compute H/δ, or own pets disk state.

## Build

```bash
cd iOS
xcodegen generate
open Shannon.xcodeproj            # select ShannonWatch scheme
```

Unsigned simulator compile:

```bash
cd iOS
xcodegen generate
xcodebuild -project Shannon.xcodeproj -scheme ShannonWatch \
  -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Pairing requires a phone build of `ShannonPhone` on a device or paired simulator
pair; without the phone relay the watch shows empty / last context only.

## Tests

There is no separate watchOS XCTest target in CI. Behaviour is covered by:

```bash
cd Packages/ShannonCore && swift test
# VoiceCommand, confirmation safety, Watch payload trimming (trimmedForWatch),
# security field walks
```

## Capabilities

| Capability | Why |
|------------|-----|
| App Group `group.com.lebonhommepharma.shannon` | Complications + face share snapshot cache |
| Keychain Sharing `com.lebonhommepharma.shannon` | Optional shared secrets (not CloudKit tokens) |
| HealthKit (optional) | Heart-rate tint only if enabled |

Full portal steps: [`docs/MULTI_DEVICE.md`](../docs/MULTI_DEVICE.md).

## Layout

```
watchOS/
  Sources/ShannonWatch/                 # face, crown, motion, voice
  Sources/ShannonWatchComplication/     # complications
  Sources/Shared/
  Resources/PrivacyInfo.xcprivacy
iOS/project.yml                         # owns watch targets + deployment 10.0
```

## Related

- iPhone host: [`iOS/README.md`](../iOS/README.md)
- Sync direction Mac → phone → watch: [`docs/MULTI_DEVICE.md`](../docs/MULTI_DEVICE.md)
