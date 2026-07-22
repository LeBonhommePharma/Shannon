# ShannonTheme

The design system for Shannon's native apps — the Mac notch pill, the iPhone
companion, and the Watch glance. One vocabulary of colour, type, motion and
spacing, so three surfaces that never appear together still read as one product.

Supports macOS 13+, iOS 16+, watchOS 9+.

## Design philosophy

**Day** is crisp, airy, high-contrast. A near-white background with cool
undertones, deep indigo accent, dark type on light. The Mac pill is frosted
glass with a subtle shadow.

**Night** is deep, focused, low-emission. Near-black with warm undertones —
`#0D0D10`, deliberately *not* pure black, which reads as a hole punched in the
screen. Electric blue accent that pops without glare. The Mac pill is dark
frosted glass, barely visible at rest, with a glowing accent border when an
agent is active.

## Using it

```swift
import ShannonTheme

Text("entropy collapse")
    .font(.shannonHeadline)
    .foregroundStyle(Color.shannonPrimary)
    .padding(ShannonSpacing.md)
    .background(Color.shannonSurface)
```

Rules of the road:

- **Never name a hex value in feature code.** Name a role — `.shannonSurface`,
  `.shannonSecondary` — and let it resolve per scheme. If a role is missing, add
  a token here rather than inlining a colour.
- **Never use a bare numeric literal for padding.** Use `ShannonSpacing`.
- **Use one of the three springs.** Not a fourth.

## How colour adaptation works

Tokens are built by `ShannonAdaptive.color(day:night:)`, which resolves *below*
SwiftUI rather than reading `@Environment(\.colorScheme)`:

| Platform | Mechanism |
|---|---|
| macOS | dynamic `NSColor` keyed off `NSAppearance` |
| iOS | dynamic `UIColor` keyed off `UITraitCollection.userInterfaceStyle` |
| watchOS | night value unconditionally — the watch interface is always dark, and watchOS has no dynamic-provider API |

Because adaptation happens at the AppKit/UIKit layer, the tokens work in
non-SwiftUI contexts, follow live system appearance changes, and respect
`.preferredColorScheme` overrides in previews.

## Colour tokens

| Token | Day | Night |
|---|---|---|
| `shannonBackground` | `#F5F6FA` | `#0D0D10` |
| `shannonSurface` | `#FFFFFF` | `#18181C` |
| `shannonSurfaceElevated` | `#ECEDF2` | `#222228` |
| `pillBackground` | `rgba(255,255,255,0.72)` | `rgba(18,18,20,0.80)` |
| `pillBorder` | `rgba(0,0,0,0.08)` | `rgba(255,255,255,0.10)` |
| `pillBorderActive` | `#4F6EF7` | `#7B9FFF` |
| `shannonAccent` | `#3A5CF5` | `#6B8FFF` |
| `shannonAccentSubtle` | `#EEF1FE` | `#1A2140` |
| `shannonPrimary` | `#0F0F12` | `#F0F0F5` |
| `shannonSecondary` | `#6B6E80` | `#8A8D9F` |
| `shannonTertiary` | `#A8ABBC` | `#4A4D5E` |
| `shannonSuccess` | `#1A7F4B` | `#34C77A` |
| `shannonWarning` | `#C47A0A` | `#F5B934` |
| `shannonError` | `#C0392B` | `#FF6B6B` |
| `shannonNeutral` | `#8A8D9F` | `#5A5D6E` |

The two pill fills keep their alpha on purpose — they sit over an
`NSVisualEffectView` using the `.hudWindow` material and must stay translucent.

## Type scale

| Token | Style | Weight | Face |
|---|---|---|---|
| `shannonLargeTitle` | `.largeTitle` | bold | SF Rounded |
| `shannonTitle` | `.title2` | semibold | SF Pro |
| `shannonHeadline` | `.headline` | semibold | SF Pro |
| `shannonBody` | `.body` | regular | SF Pro |
| `shannonCallout` | `.callout` | medium | SF Pro |
| `shannonCaption` | `.caption` | regular | SF Pro, monospaced digits |
| `shannonMono` | `.caption` | regular | SF Mono |

Every token is derived from a *text style*, not a fixed point size, so Dynamic
Type works everywhere and `.dynamicTypeSize(...)` clamps behave. `shannonMono`
is for anything compared column-wise: RMSD values, CF scores, entropy in bits,
turn counts. `shannonCaption` uses monospaced digits so live counters don't
jitter as they tick.

## Motion

| Token | Spring | Use |
|---|---|---|
| `shannonSnap` | `response 0.25, damping 0.80` | tap response, toggles |
| `shannonEase` | `response 0.40, damping 0.75` | card expansion, list reflow |
| `shannonFloat` | `response 0.60, damping 0.65` | pill expand/collapse |

Damping falls as travel grows: a tap barely overshoots, a pill unfurling from
the notch is allowed a little bounce.

## Spacing

8pt grid — `xs 4` (the single permitted half-step), `sm 8`, `md 16`, `lg 24`,
`xl 32`, `xxl 48`. Companion enums: `ShannonRadius` (`sm 8`, `md 12`, `lg 16`,
`xl 20`) and `ShannonStroke` (hairline `0.5`, glow radius `8`, glow opacity
`0.4`).

## Platform layout specs

All of these live in `ShannonLayout` — reference them rather than re-deriving
sizes locally.

**macOS pill, collapsed** — 160×32pt, corner radius 16. `pillBackground` over
the HUD material, `pillBorder` hairline. One line only: icon + text.

**macOS pill, expanded** — 320pt wide, height = content + 32pt (16pt padding top
and bottom), corner radius 20. Springs open from the centre with
`.shannonFloat`, over an `NSVisualEffectView` using `.hudWindow`.

**iOS card** — full width minus 32pt (16pt page margin each side), corner radius
16, `shannonSurface` background, 16pt internal padding.

**watchOS card** — full width, corner radius 12, `shannonBackground` fill, 8pt
padding, text clamped to 2 lines.

## Ready-made chrome

```swift
// macOS: material, tint, hairline, shadow, and the active accent glow.
content.shannonPill(isActive: agent.isRunning)

// iOS / watchOS: picks up the right radius and padding per platform.
content.shannonCard(isHighlighted: isSelected)

// Shared status dot driven by the semantic state colours.
ShannonStatusDot(state: .success)
```

`PillStyle` is compiled only on macOS. `ShannonCardStyle` resolves to the 16pt
radius / 16pt padding iOS geometry, or the 12pt / 8pt watchOS geometry, from the
same call site.

## Specimen sheet

`ShannonThemeSpecimen` (DEBUG only) renders every colour token, the full type
scale, the spacing grid and both pill states. Open
`Sources/ShannonTheme/ShannonThemePreview.swift` in Xcode and the canvas shows
Day and Night side by side — the fastest way to check a new token against the
rest of the palette before it ships.

## How it plugs into the rest of Shannon

```
ShannonTheme   (presentation: colour, type, motion, spacing) ──┐
                                                               ├──> app targets
ShannonCore    (model: AgentState, ShannonStore, ShannonSync) ─┘
```

The two packages are deliberately **independent**, and app targets compose them.
`ShannonCore` is a pure model layer — states, storage, sync — with no views in
it, so it has nothing to colour; making it depend on a presentation package
would force every consumer (including headless ones) to link SwiftUI and would
point the dependency arrow the wrong way. Map core state to theme tokens at the
view layer instead:

```swift
import ShannonCore
import ShannonTheme

extension AgentActivity {
    var tint: Color {
        switch self {
        case .running:  return .shannonAccent
        case .idle:     return .shannonNeutral
        case .blocked:  return .shannonWarning
        case .errored:  return .shannonError
        case .finished: return .shannonSuccess
        }
    }
}
```

That mapping ships for real in
`Pill/Sources/ShannonPill/AgentActivity+Theme.swift`, which also provides
`dotState` (for `ShannonStatusDot`) and `lightsPillBorder`.

The Mac pill (`Pill/`) already depends on this package:

```swift
dependencies: [
    .package(path: "../Packages/ShannonTheme"),
],
targets: [
    .executableTarget(
        name: "ShannonPill",
        dependencies: ["PillCore", .product(name: "ShannonTheme", package: "ShannonTheme")]
    ),
]
```

For iOS and watchOS targets in an Xcode project, drag
`Packages/ShannonTheme` into the project navigator and add **ShannonTheme** to
each target's *Frameworks, Libraries, and Embedded Content*.

### A note on the pill's own metrics

`Pill/Sources/ShannonPill/PillView.swift` keeps its existing `PillMetrics`
(240×32 collapsed, 380×168 expanded) rather than adopting
`ShannonLayout.Pill`'s 160/320 spec, because the shipping pill carries media
artwork, transport controls and a battery ring that do not fit the narrower
spec. It uses the theme for *chrome* — colour, border, glow, motion. Reconciling
the two is a deliberate follow-up, not an oversight.

The pill also keeps fixed 9–13pt font sizes instead of the Dynamic Type scale:
its container is a fixed-height notch that cannot grow with the user's text
size. Dynamic Type applies to the iPhone and Watch companions, where the layout
can actually reflow.

## Tests

```bash
swift test --package-path Packages/ShannonTheme
```

Covers hex decoding and straight alpha, the 8pt grid invariant, token-name
uniqueness, catalogue completeness, and the layout specs.
