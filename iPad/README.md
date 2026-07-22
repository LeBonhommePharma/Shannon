# Shannon for iPad

A dedicated agent-coordination dashboard, not a scaled-up iPhone app. The
phone answers "what is Shannon doing right now?" in a scrolling list; the iPad
answers "what are all of them doing, and which one needs me?" on one canvas.

```bash
cd iPad && xcodegen generate && open ShannonPad.xcodeproj
```

The `.xcodeproj` is generated and not checked in — regenerate after adding
source files.

## Layout

One `NavigationSplitView`, reconfigured rather than rebuilt as the window
resizes. The branch lives in `HubLayout.resolve(width:sizeClass:)`:

| Width | Layout | Columns |
|---|---|---|
| < 600pt (Slide Over, compact) | `.compact` | card list in a `NavigationStack` |
| 600–1100pt (half screen, portrait) | `.twoColumn` | 280pt sidebar + detail |
| ≥ 1100pt (landscape, wide Stage Manager) | `.threeColumn` | 240pt rail + detail + 320pt feed |

State lives above the branch in `AgentHubViewModel`, so resizing across a
breakpoint keeps the selection and the accumulated chart history instead of
restarting them.

The dashboard grid reflows independently: 1 column under 600pt, 2 under 900,
3 under 1250 (11" landscape), 4 above (13").

## What is on screen

- **Agent cards** — status dot, task, turn count, entropy H, and a sparkline of
  H over the samples this iPad has seen.
- **FlexAID∆S card** — progress ring (N/85), current target, best RMSD against
  the 2.0 Å cutoff, ETA, and the RMSD trace with the cutoff drawn in.
- **Now Playing** — artwork, a waveform-shaped scrubber, transport. Every
  control is a `RemoteCommand` to the Mac, not local playback.
- **Power** — Mac battery from the synced snapshot, this iPad's own battery
  read locally, AirPods as unknown (see *Not wired up* below).
- **Entropy chart** — H per agent against the collapse band, in SwiftUI Charts.

## Interaction

**⌘K palette** — fuzzy subsequence search over agents, benchmark targets and
commands. `PaletteCatalogue` is the single list that the palette, the keyboard
shortcuts and the spoken commands all resolve against.

**Keyboard** — `⌘K` palette, `⌘0` overview, `⌘1`…`⌘9` focus by sidebar position
(the position is printed in each row), `⌘↵` confirm, `⌘.` deny, `⌘R` refresh,
`⌘⇧D` dictation, `⌘Space` play/pause.

**Voice** — `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`.
That is not a preference: agent transcripts name internal targets and file
paths, so when on-device recognition is unavailable the app says so rather
than falling back to a speech server. Phrases are parsed by
`ShannonCore.VoiceCommand`, shared with the Mac and Watch; the iPad adds a
fuzzy jump on `.freeform` since it has a screen worth navigating.

**Pencil** — `PKCanvasView` over any card. Drawings persist as `PKDrawing`
vector data (never rasterised) under `Documents/pets/{agent_id}/annotations/`,
mirroring the Mac's `~/.shannon/pets/{agent_id}/annotations/` so a future sync
can copy the subtree verbatim. A long press on the FlexAID∆S card opens an ROI
canvas over a schematic pocket placeholder.

**Drag and drop** — drag an agent card onto another to link them; valid targets
get a dashed accent border and the connection is drawn as a curve with an
arrowhead at the consuming end. The payload uses a private UTI
(`com.lebonhommepharma.shannon.agent`), so dragging a card into Notes in Split
View does nothing instead of pasting a raw identifier.

**Context menus** — on every card, reachable by long press or trackpad
right-click.

**Notification rail** — pending confirmations pinned above the feed with
full-size Confirm/Deny buttons and the prompt's expiry counting down. Swipe
right to dismiss a notification, left to mark it important.

## Deployment target

The source targets the iPadOS 16 API surface, but the project is set to **iOS
17.0** for two reasons: `ShannonCore.ShannonStore` is `@Observable`
(`@available(iOS 17.0, *)`), and Xcode 27 rebuilds Swift package dependencies
at its recommended floor of 17 regardless of what the package declares.

## Not wired up

Honest gaps, so nothing on screen implies more than it does:

- **AirPods battery** — no record type carries it. The ring renders as unknown
  rather than showing a made-up number.
- **Run Benchmark** — `RemoteCommand` only carries playback today, so there is
  no record the Mac would pick up. The palette entry navigates to the benchmark
  and says so.
- **Cancel run / Export CSV** — context-menu entries exist; both need the same
  missing Mac-side command channel.
- **Per-target RMSD** — only `bestRMSD` is synced, so the target list shows
  position and completion, not per-target results.
- **Pocket geometry** — the ROI canvas draws over a schematic placeholder until
  FlexAID∆S exports real pocket geometry.

## Verification status

`xcodebuild` for the iPad Pro 11" simulator succeeds, and the app installs.
Runtime behaviour is **not** verified: this host's Xcode 27 beta is missing
`SimulatorKit.framework`, and `simctl` hangs after launch, so no screenshot of
the running hub was obtained.
