# Multi-device companion apps

Shannon's Mac agent hub publishes its state to iCloud so an iPhone and Apple
Watch on the same iCloud account can follow along. This document covers the
architecture and the one-time Xcode configuration needed to activate sync.

## Architecture

```
  Mac (ShannonPill)                  iPhone (ShannonPhone)         Apple Watch
  ┌────────────────┐                 ┌───────────────────┐        ┌──────────┐
  │ NowPlayingModel│                 │   ShannonStore    │        │WatchRelay│
  │ BatteryMonitor │──ShannonPublisher──▶ CloudKit ──────▶│───WC───▶  views   │
  │ ShannonBridge  │   (CloudKit)    │  + widget + push  │        │+ complic.│
  └────────────────┘                 └───────────────────┘        └──────────┘
          ▲                                    │                        │
          └────────── RemoteCommand ◀──────────┴──── playback taps ◀────┘
```

- **Mac → iPhone** uses **CloudKit** (private database, custom zone
  `ShannonState`). Only state snapshots cross the wire — never raw data files,
  transcripts, or docking output.
- **iPhone → Watch** uses **WatchConnectivity** (`updateApplicationContext`),
  which keeps only the latest payload queued. The watch never queries CloudKit;
  it is a display relay, so its radio stays out of the sync path.
- **Playback commands** flow the other way: the watch messages the phone, the
  phone writes a `RemoteCommand` record, and the Mac drains and executes it.
  Commands older than 60 s are discarded rather than executed late.

### Synced record types

| Record type | Contents | Record naming |
|---|---|---|
| `AgentState` | activity, task title, turn count, last action, entropy H and δ | `agent-<id>` |
| `DockingProgress` | benchmark, targets complete/total, best RMSD, success rate, ETA | `docking-<id>` |
| `NowPlaying` | track, artist, album, position, downsampled artwork | `nowplaying-current` |
| `MacDeviceState` | battery %, charging, time remaining | `device-<name>` |
| `NotificationMirror` | sender, title, truncated body | `notification-<id>` |
| `TimerState` | label, deadline, paused state | `timer-<id>` |
| `RemoteCommand` | playback command from phone/watch | `command-<uuid>` |

Every record except `RemoteCommand` uses a **stable record name**, so
republishing overwrites in place instead of accumulating history. The publisher
also suppresses writes when nothing but the timestamp changed, which keeps a
1 s poll loop from burning the CloudKit request quota.

### Sync budget

- Artwork over 200 KB is dropped before publishing (`NowPlayingSnapshot.trimmedForSync`).
- Notification bodies are truncated to 140 characters at construction.
- Watch payloads carry no artwork and at most 5 notifications
  (`ShannonSnapshot.trimmedForWatch`).

## Layout

```
Packages/ShannonCore/          shared Swift package (macOS 13+, iOS 16+, watchOS 9+)
  Sources/ShannonCore/
    AgentState.swift           agent snapshot + display ranking
    DockingProgress.swift      benchmark progress + edge-triggered alerts
    NowPlayingState.swift      media snapshot + RemoteCommand
    MacDeviceState.swift       battery, notification mirror, timers
    CloudRecord.swift          CloudValue field model, typed decoding
    ShannonSync.swift          CloudKit backend, snapshot aggregate, watch codec
    ShannonStore.swift         observable store + Mac-side publisher
  Tests/ShannonCoreTests/      41 tests, no CloudKit container required

iOS/
  project.yml                  XcodeGen spec for all four app targets
  Sources/ShannonPhone/        SwiftUI app, watch relay, haptics
  Sources/ShannonWidget/       WidgetKit widget (Lock/Home Screen)
  Sources/Shared/              App Group snapshot bridge

watchOS/
  Sources/ShannonWatch/        watch app + WatchConnectivity relay
  Sources/ShannonWatchComplication/  watch face complication
  Sources/Shared/              App Group snapshot cache

Pill/Sources/ShannonPill/CloudPublishing.swift   Mac publishing side
```

## Building

```bash
# Shared package — runs anywhere, no entitlements needed
cd Packages/ShannonCore && swift test

# iPhone + Watch apps
cd iOS && xcodegen generate
xcodebuild -project Shannon.xcodeproj -scheme ShannonPhone \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Shannon.xcodeproj -scheme ShannonWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Mac hub (publishes state)
cd Pill && swift build && swift test
```

The `.xcodeproj` is generated and not checked in — regenerate it after adding
source files.

## What LP needs to configure in Xcode

Everything above **builds and runs today** without an Apple Developer account.
Without the entitlements below, both apps fall back to an empty in-memory
backend: they launch, render their empty state, and sync nothing. Activating
real sync requires a paid Apple Developer account and these one-time steps.

### 1. Create the iCloud container

In the [Apple Developer portal](https://developer.apple.com/account/resources/identifiers/list/cloudContainer),
create a container with exactly this identifier:

```
iCloud.com.lebonhommepharma.shannon
```

It must match `ShannonSyncConfig.containerID`. If you use a different one,
change that constant rather than editing each target's entitlements.

### 2. Signing & Capabilities per target

Open `iOS/Shannon.xcodeproj` and set **Team** on all four targets
(`ShannonPhone`, `ShannonWidget`, `ShannonWatch`, `ShannonComplication`), then
add these capabilities:

| Target | Capabilities |
|---|---|
| ShannonPhone | iCloud → **CloudKit** (check the container above); **App Groups** → `group.com.lebonhommepharma.shannon`; **Push Notifications**; Background Modes → **Remote notifications** |
| ShannonWidget | **App Groups** → `group.com.lebonhommepharma.shannon` |
| ShannonWatch | **App Groups** → `group.com.lebonhommepharma.shannon` |
| ShannonComplication | **App Groups** → `group.com.lebonhommepharma.shannon` |

The entitlement files are already generated by XcodeGen with these values —
Xcode still needs the capability enabled on the provisioning profile, which is
what the portal round-trip does.

The App Group is not optional: widgets and complications run in separate
processes and cannot read the host app's sandbox. Without it, the widget and
the watch face complication render placeholder data while the apps themselves
work fine.

### 3. Mac app entitlements

`Pill/` builds as a SwiftPM executable, which is unsigned and therefore has no
iCloud access. To publish for real, generate and sign the Xcode target:

```bash
cd Pill && xcodegen generate && open ShannonPill.xcodeproj
```

Then on the `ShannonPill` target: set **Team**, add **iCloud → CloudKit** with
the same container, and add the same App Group. Note the pill runs unsandboxed
(MediaRemote and IOKit power sources are unreachable from a sandboxed process),
which does not conflict with CloudKit.

### 4. Deploy the CloudKit schema

On first run in the **Development** environment, CloudKit creates record types
automatically from the records the Mac writes. Once the phone shows real state,
open the [CloudKit Console](https://icloud.developer.apple.com/) and use
**Deploy Schema to Production** before shipping to any other device.

Queryable indexes are needed on `recordName` for each record type — the console
flags this the first time a query runs.

### 5. Verifying it works

1. Run the Mac pill with a track playing.
2. Launch the iPhone app — the Now Playing card and Mac battery card appear
   within ~10 s (the publish interval).
3. Tap next-track on the phone; the Mac skips within one publish cycle.
4. With the watch paired and the phone app foregrounded, the watch shows the
   same three cards.

If the phone shows "Can't reach iCloud", the device is not signed into iCloud
or the container entitlement is missing — those are the only two causes of that
banner.

## Credentials

No credentials are stored by any of this. CloudKit authenticates through the
signed-in iCloud account; the apps never see a token. This keeps Shannon's rule
that all credentials live in the Keychain — there is simply nothing here to
put in it.
