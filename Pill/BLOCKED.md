# Blocked / constrained features

Platform limits hit while building the live-activity pill. Recorded here so the
next person does not re-derive them. Verified on **macOS 27.0 (build 26A5378n)**
with Xcode 27 / Swift 6.4, via `ShannonPill --probe`.

---

## 0. CloudKit traps on unsigned launch — FIXED (failsafe)

**Symptom (macOS 27):** double-clicking `/Applications/Shannon.app` appeared to
"do nothing". Process wrote a boot line then died with `EXC_BREAKPOINT`.

**Root cause:** `CloudPublisher.defaultBackend()` constructed
`CloudKitSyncBackend()` → `CKContainer(identifier:)` whenever CloudKit headers
were importable. Without an iCloud entitlement (ad-hoc / Homebrew install),
AppKit traps hard — not a catchable Swift error.

**Fix:** default backend is always `InMemorySyncBackend`. CloudKit is only
constructed when `SHANNON_ICLOUD=1` **and** an embedded provisioning profile is
present. Menu-bar status item + idle telemetry keep the UI alive even with no
Python bridge.

---

## 1. Now Playing for *other* apps has no public API — BLOCKED, partially mitigated

**What the brief asked for:** read track/artist/artwork from Apple Music,
Spotify, browsers and VLC via "AVFoundation / NowPlayingManager".

**Why that cannot work as written:** `MPNowPlayingInfoCenter` is a *publishing*
API. A process can only read back what it itself published — there is no public
call that returns another application's Now Playing state. AVFoundation does not
expose it either. Every notch utility that shows system-wide media (Islet
included) uses the private **MediaRemote** framework.

**What we did:** `MediaRemoteProvider` `dlopen`s
`/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote` and
resolves `MRMediaRemoteGetNowPlayingInfo`, `MRMediaRemoteSendCommand`,
`MRMediaRemoteRegisterForNowPlayingNotifications` and
`MRMediaRemoteSetElapsedTime`. Every call site tolerates a nil symbol, so the
pill degrades to the entropy readout instead of crashing.

**Current status on this machine:**

```
mediaremote: symbols resolved
now playing: no data (entitlement-gated, or nothing playing)
```

Symbols resolve, but no payload was delivered. Two candidate causes, and the
probe was run with no media playing, so they are **not disambiguated**:

- Starting with **macOS 15.4** Apple gated `MRMediaRemoteGetNowPlayingInfo`
  behind `com.apple.mediaremote.now-playing-info`, a private entitlement not
  granted to third-party developers. On a gated system the callback fires with
  an empty dictionary. This machine (macOS 27) is well past that cutoff, so
  this is the expected cause.
- Nothing was playing, which produces the same empty result.

**To disambiguate:** start any media, then run
`Pill/.build/debug/ShannonPill --probe`. If it still reports no data, the
entitlement wall is confirmed on this OS.

**Fallback options if confirmed (none implemented yet):**

| Option | Coverage | Cost |
|---|---|---|
| ScriptingBridge / AppleScript per app | Music, Spotify only — not browsers or VLC | Needs Automation consent per app; no artwork for some |
| Accessibility tree scraping | Broad but brittle | Breaks on every UI redesign |
| Browser extension for web audio | Browsers only | A whole second product |
| Ship unsigned / user-installed with entitlement | Full | Not distributable |

The UI already surfaces this: when the provider reports unavailable, the
expanded pill shows "Now Playing unavailable — see BLOCKED.md", and the
collapsed pill falls back to the Shannon entropy readout.

---

## 2. Focus / Do Not Disturb status — BLOCKED (P1, not attempted)

The brief suggested `CNContactStore` or `com.apple.donotdisturb`. Neither is a
supported read path:

- `CNContactStore` is the Contacts database and has nothing to do with Focus.
- Focus state lives in `~/Library/DoNotDisturb/DB/Assertions.json` and
  `ModeConfigurations.json`. Reading it is possible but the files are inside the
  app-data TCC boundary, undocumented, and their schema has changed repeatedly
  across releases.
- `NSUserNotificationCenter`'s DND query was removed; the modern replacement
  (`UNUserNotificationCenter.getNotificationSettings`) reports *your own* app's
  authorization, not the system Focus mode.

Not implemented. If pursued, treat the JSON files as a best-effort read with a
schema-version guard and a hard fallback to "unknown".

---

## 3. Notification mirroring — BLOCKED (P0 in the brief, not shipped)

There is no macOS API for observing another application's notifications.
`UNUserNotificationCenterDelegate` only ever delivers notifications your own
process posted. The routes that exist:

- **AppleScript into Messages/Mail** — needs Automation consent per app, only
  covers those apps, and polls rather than observes.
- **Accessibility observation of the Notification Center window** — requires
  Accessibility (already a stated requirement) and `AXObserver` on
  `com.apple.notificationcenterui`. Fragile, and Apple has repeatedly changed
  the view hierarchy.
- Reading `~/Library/Group Containers/group.com.apple.usernoted/db2/db` — an
  undocumented SQLite store, TCC-protected, and it does not notify on write.

Deferred rather than shipped half-working, since a notification mirror that
silently misses messages is worse than none. The DND gate it depends on is
itself blocked (§2).

---

## 4. AirDrop incoming — BLOCKED (P1, not attempted)

`NCServiceBrowserDelegate` and "AirDropDetector" in the brief are not public
API; neither name exists in a public SDK. Incoming AirDrop is handled entirely
by Finder and `sharingd`, with no notification or observer surface for third
parties. The only observable signal is filesystem activity in `~/Downloads`
(via `FSEvents`), which cannot attribute a file to a sender or offer
Accept/Decline — the accept decision has already happened by then.

---

## 5. App Sandbox must stay off

Both shipped features are incompatible with the sandbox:

- IOKit power sources (`IOPSCopyPowerSourcesInfo`) return nothing sandboxed.
- MediaRemote cannot be loaded from a sandboxed process at all.

`project.yml` therefore enables Hardened Runtime but not App Sandbox. **This
means the app cannot ship on the Mac App Store.** Distribution has to be
Developer ID + notarization, or direct/unsigned for internal use.

---

## 6. Head-gesture confirmation — NOT blocked, but two corrections

Implemented and shipping. Recorded here because the spec it was built from was
wrong on two points, both checked against the macOS 27 SDK headers rather than
assumed:

- **It is macOS 14, not macOS 11.** `CMHeadphoneMotionManager` is declared
  `API_AVAILABLE(macos(14.0), ios(14.0), watchos(7.0))`. CoreMotion as a
  framework is older, but this class is Sonoma-era. Since the pill targets
  macOS 13, `HeadphoneMotionProvider` is `@available(macOS 14.0, *)` and
  `makeHeadphoneMotionProvider()` returns an "unavailable" stand-in on Ventura
  that explains itself in the UI. Raising the deployment target to 14 would
  have been the alternative; keeping 13 preserves the documented support range.

- **There is no `com.apple.headphone-motion` entitlement.** No such key exists.
  Headphone motion is ordinary TCC consent, reported via
  `CMHeadphoneMotionManager.authorizationStatus()` and prompted by the
  `NSMotionUsageDescription` Info.plist string, which is present in both the
  SwiftPM plist and the XcodeGen spec. Within CoreMotion, only
  `CMFallDetectionManager` requires an Apple-granted entitlement. If motion is
  later denied, the user must re-enable it in System Settings > Privacy &
  Security > Motion & Fitness — an app cannot re-prompt.

**Not yet verified on hardware.** The detector has 27 unit tests driving
synthetic attitude streams, and `--probe` reports
`gestures: available — motion access not yet requested` on this machine, which
confirms the class resolves and TCC has not been asked yet. But no AirPods were
connected during development, so the end-to-end path — real consent prompt,
real `CMDeviceMotion` attitude stream, and the 15° / 0.8 s thresholds against
an actual human nod — is **unproven**. Expect the thresholds to need tuning;
they are all in `HeadGestureConfig` for exactly that reason. Verify with:

```bash
Pill/.build/debug/ShannonPill --probe          # should say "authorized"
Pill/build/ShannonPill.app/Contents/MacOS/ShannonPill --demo   # poses a prompt
```

---

## 8. AirPods integration — most of the requested API surface is iOS-only

The AirPods brief was written against iOS APIs. Checked against the macOS 27
SDK, here is what actually exists.

**`AVAudioSession` does not exist on macOS.** The header is present in
`AVFAudio.framework` but every member is annotated
`API_AVAILABLE(ios, watchos, tvos) API_UNAVAILABLE(macos)`. That single fact
blocks four requested items:

| Requested | Status |
|---|---|
| `routeChangeNotification` for in-ear detection (§1) | ❌ no such notification on macOS |
| `preferredMicrophoneMode = .voiceIsolation` (§5) | ❌ `AVAudioSession` unavailable |
| `setPreferredMicrophoneInjectionMode` (§5) | ❌ same |
| `isOtherAudioPlaying` guard (§ "never override a call") | ❌ same |
| `currentRoute.outputs.first?.portType` (§8) | ❌ same |

**What was built instead.** `CoreAudioRouteProvider` listens on
`kAudioHardwarePropertyDefaultOutputDevice`, which is the macOS equivalent for
route changes. It detects AirPods **connecting and disconnecting** as the
default output, reads the device name and Bluetooth transport type, and
classifies the model for the pill indicator (§8 minus noise-control mode).

**In-ear detection is not achievable.** macOS exposes no ear-detection API at
all. Removing an AirPod usually makes macOS switch the default output away
after a delay, which surfaces here as a disconnect — but that is a side effect
with different timing, not the requested signal. Announcements are held on
disconnect, which covers the practical intent of §1.

**Conversation Awareness (§4) has no public API** on any platform. Nothing to
subscribe to; the feature works on the audio Apple renders, not on ours.

**Noise-control mode (§8) is not readable.** No public API reports
transparency/ANC state to third parties.

### Stem and Digital Crown presses (§2) — compiles, but semantically wrong

`MPRemoteCommandCenter` **is** available (`MP_API(macos(10.12.2))`), so the
code in the brief would build. It would not work as intended:

remote commands are delivered only to the app the system considers the **Now
Playing app**. Shannon publishes no audio, so AirPods stem presses go to Music,
Spotify, or whatever is actually playing. For Shannon to receive them it would
have to claim the Now Playing role — at which point a stem press stops
controlling the user's music, which is precisely the "never override" rule the
brief itself sets out. §2 also conflicts directly with §4: speaking
announcements through Shannon is what would make it the Now Playing app.

Not implemented. Head gestures already provide contextual confirm/deny without
hijacking anyone's transport controls.

### AirPods battery (§3) — no third-party path

AirPods do not expose the GATT Battery Service (0x180F / 0x2A19) to
third-party `CoreBluetooth` clients; they are not connectable as a generic
BLE peripheral. Battery percentages surface only through private
`BluetoothManager`/`IORegistry` keys (`BatteryPercentCombined`,
`BatteryPercentCase`) which are undocumented, unstable across releases, and
absent entirely for some models. Not implemented. The Mac's own battery ring
(shipped, §Battery) is unaffected.

### Spatial positioning of announcements (§4)

`AVAudioEnvironmentNode` exists on macOS, but `AVSpeechSynthesizer` renders to
the system output device and cannot be inserted into an `AVAudioEngine` graph,
so its output cannot be positioned at front-centre. Announcements are plain
stereo. Routing synthesized speech through the engine would require rendering
to buffers via `write(_:toBufferCallback:)` and losing system voice routing —
judged not worth it for a positional cue.

### Head-orientation browse mode (§6)

Not implemented. `CMHeadphoneMotionManager` already streams continuous
attitude, so this is genuinely available — it was descoped for time, not
blocked. `HeadGestureDetector` would need a second mode that reports sustained
yaw offset rather than discrete gestures.

---

## 9. Voice dictation — shipped, with one caveat

`SFSpeechRecognizer` is `API_AVAILABLE(macos(10.15))` and
`requiresOnDeviceRecognition` is `macos(10.15)`, so both clear the pill's
macOS 13 floor. Dictation is implemented and on-device only.

**The caveat:** `requiresOnDeviceRecognition = true` is set unconditionally and
never relaxed. If the user's locale has no on-device model installed,
`supportsOnDeviceRecognition` is false and dictation reports unavailable rather
than falling back to server recognition. This is deliberate — the privacy
promise is unconditional — but it means dictation silently does not work for
some locales until the user downloads the language model.

**Not verified against a live microphone.** The recognizer, audio tap and
engine wiring are untested end to end; no microphone session was run during
development. The parser and dispatch logic have 32 unit tests.

---

## 10. Permissions summary

| Capability | Permission | Status |
|---|---|---|
| Battery / charging ring | none | ✅ works, verified |
| Shannon entropy bridge | none (local Unix socket, 0600) | ✅ works, verified |
| Now Playing metadata | private entitlement | ⚠️ symbols resolve, no data |
| Now Playing transport control | Accessibility | untested (needs §1 resolved) |
| AirPods battery | Bluetooth | not implemented |
| Head-gesture confirm | Motion & Fitness (TCC only) | ✅ built, macOS 14+, untested on hardware |
| Voice dictation | Microphone + Speech Recognition (TCC) | ✅ built, on-device only, untested with a live mic |
| AirPods route / model indicator | none (CoreAudio) | ✅ built |
| AirPods in-ear detection | — | ❌ no macOS API |
| AirPods battery | — | ❌ no third-party API |
| Stem / Crown presses | — | ❌ requires hijacking Now Playing |
| Notification mirror | Accessibility + Automation | ❌ blocked (§3) |
| Focus / DND | none available | ❌ blocked (§2) |
| AirDrop | none available | ❌ blocked (§4) |
