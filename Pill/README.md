# Shannon Pill

A notch-hugging live-activity pill for macOS, and the Swift front end for the
Shannon agent coordination layer.

The pill sits in (or under) the notch as an `LSUIElement` agent app — no dock
icon, no menu bar item, no app-switcher entry. Hovering expands it. Collapsed,
it shows whichever signal is most relevant: media if something is playing,
otherwise the live Shannon entropy readout from the Python agent.

> **Status: P0 partial.** Battery and the Python bridge are implemented and
> verified end to end. Now Playing is implemented but gated by a private Apple
> entitlement on current macOS — see [BLOCKED.md](BLOCKED.md). Notification
> mirroring, Focus/DND, AirDrop and the file shelf are **not** implemented.

---

## Build and run

The canonical build is SwiftPM:

```bash
cd Pill
swift build              # compile
swift test               # 42 unit tests
./Scripts/make_app.sh    # assemble build/ShannonPill.app (adds LSUIElement)
open build/ShannonPill.app
```

For Xcode (signing, Instruments, debugging the UI):

```bash
cd Pill
xcodegen generate        # writes ShannonPill.xcodeproj (not checked in)
open ShannonPill.xcodeproj
```

Two useful flags:

```bash
./build/ShannonPill.app/Contents/MacOS/ShannonPill --demo    # stub media source
./build/ShannonPill.app/Contents/MacOS/ShannonPill --probe   # diagnostics, then exit
```

`--probe` reports what actually works on the current machine:

```
Shannon Pill probe — Version 27.0 (Build 26A5378n)
  battery:     OK — 100% discharging, Calculating…
  mediaremote: symbols resolved
  now playing: no data (entitlement-gated, or nothing playing)
  bridge:      OK at /Users/you/.shannon/pill.sock — H 7.2 ▽0.6, backend demo
```

Stop the app with `pkill -f ShannonPill` — with no dock icon there is nothing
to quit from.

---

## Architecture

```
Pill/
  Sources/
    PillCore/                 platform logic, no UI — this is what the tests cover
      Battery.swift           IOKit polling, alert edge-triggering
      NowPlaying.swift        media state machine, provider protocol, stub provider
      MediaRemoteProvider.swift   private-framework bridge (see BLOCKED.md)
      ShannonBridge.swift     Unix-socket client for the Python agent
    ShannonPill/              AppKit + SwiftUI, no logic worth testing
      ShannonPillApp.swift    @main entry, --demo / --probe
      NotchGeometry.swift     where the pill sits on a given screen
      PillWindowController.swift  the non-activating panel
      PillView.swift          collapsed + expanded SwiftUI
  Tests/PillCoreTests/        42 tests
  Resources/Info.plist        literal plist for the SwiftPM bundle
  project.yml                 XcodeGen spec
  Scripts/make_app.sh         SwiftPM binary → .app
```

`PillCore` deliberately holds every decision worth asserting on — capacity
parsing, alert thresholds, media transitions, label truncation, wire framing —
so the suite runs without a window server, a media session or a live agent.
Each hardware source sits behind a protocol (`BatteryProviding`,
`NowPlayingProviding`) with a deterministic stub.

### Where the pill sits

`NotchGeometry` derives the notch rect from `NSScreen.safeAreaInsets.top` plus
`auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. On a Mac with no notch — an
external display, or an older machine — it synthesises an equivalent rect
centred on the menu bar, so the UI is identical and simply floats rather than
hugs. The panel is `.borderless` + `.nonactivatingPanel` above
`CGWindowLevelForKey(.statusWindow)`, so it never steals focus from what the
user is typing into.

---

## Features

### Battery and charging ✅

IOKit `IOPSCopyPowerSourcesInfo`, polled every 15 s. A circular ring shows
charge; the ring pulses **amber at ≤20%** and **red at ≤10%**, and stays calm
while charging — a Mac at 8% on the cable is recovering, not in trouble.

Alerts are **edge-triggered** by `BatteryAlertTracker`: crossing into low fires
once, not on every poll while sitting there, and the full-charge alert re-arms
only after the battery drains below 95%. Capacity is converted from IOKit's
raw device units, and `-1` time estimates render as "Calculating…" rather than
a nonsense duration.

### Now Playing ⚠️

Album art, title, artist, a scrubber and previous/play-pause/next in the
expanded pill; `▶ track — artist` when collapsed, truncated to fit the notch.
The state machine handles live streams (zero duration → elapsed is not clamped)
and treats empty metadata as "nothing loaded".

**The data source is gated.** macOS has no public API to read another app's
Now Playing state, so this goes through the private MediaRemote framework,
which Apple entitlement-gated in macOS 15.4. On a gated system the pill shows
"Now Playing unavailable" and falls back to the entropy readout. Full detail
and fallback options in [BLOCKED.md](BLOCKED.md).

### Shannon agent bridge ✅

The Swift app is a pure consumer of the Python coordination layer over a local
Unix domain socket — newline-delimited JSON, one exchange per connection,
nothing leaves the machine.

```
-> {"command": "status"}
<- {"entropy": 8.42, "delta_h": -3.51, "collapsed": false,
    "token_count": 1024, "backend": "cpp", "agent": "flexaid-runner"}
```

Serve it from any detector:

```python
from shannon import ShannonCollapseDetector
from shannon.pill_bridge import PillBridgeServer

detector = ShannonCollapseDetector()
with PillBridgeServer(detector, agent="flexaid-runner") as server:
    server.serve_in_thread()
    ...  # run the agent; the pill picks it up within a second
```

Or drive the UI with a synthetic trace:

```bash
python -m shannon.pill_bridge --demo
```

The socket is created `0600` under `~/.shannon/pill.sock`
(override with `SHANNON_PILL_SOCKET`, honoured by both sides). It answers
`status` and nothing else — it is a readout, not an RPC surface, so a
compromised local process cannot use it to drive the agent. The pill polls once
a second on a background queue; a missing socket reads as "agent offline"
rather than an error.

The footer dot goes green when connected, and the entropy label turns amber
when the detector reports a collapse.

---

## Permissions

| Capability | Permission | Required? |
|---|---|---|
| Battery ring | none | — |
| Entropy bridge | none | — |
| Now Playing metadata | private entitlement (unavailable) | see BLOCKED.md |
| Now Playing transport | Accessibility | optional |

The app is **not sandboxed** — IOKit power sources and MediaRemote are both
unreachable from a sandboxed process. It therefore cannot ship on the Mac App
Store; distribution is Developer ID + notarization, or direct.

Target is macOS 13 Ventura+. `make_app.sh release` produces a universal
(arm64 + x86_64) binary.

---

## Not implemented

Deferred with reasons in [BLOCKED.md](BLOCKED.md): notification mirroring (§3),
Focus/DND status (§2), AirDrop (§4). Timers and the drag-and-drop file shelf are
straightforward but were not reached — neither is blocked by a platform limit.
