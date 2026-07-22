# Blocked / constrained features

Platform limits hit while building the live-activity pill. Recorded here so the
next person does not re-derive them. Verified on **macOS 27.0 (build 26A5378n)**
with Xcode 27 / Swift 6.4, via `ShannonPill --probe`.

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

## 7. Permissions summary

| Capability | Permission | Status |
|---|---|---|
| Battery / charging ring | none | ✅ works, verified |
| Shannon entropy bridge | none (local Unix socket, 0600) | ✅ works, verified |
| Now Playing metadata | private entitlement | ⚠️ symbols resolve, no data |
| Now Playing transport control | Accessibility | untested (needs §1 resolved) |
| AirPods battery | Bluetooth | not implemented |
| Head-gesture confirm | Motion & Fitness (TCC only) | ✅ built, macOS 14+, untested on hardware |
| Notification mirror | Accessibility + Automation | ❌ blocked (§3) |
| Focus / DND | none available | ❌ blocked (§2) |
| AirDrop | none available | ❌ blocked (§4) |
