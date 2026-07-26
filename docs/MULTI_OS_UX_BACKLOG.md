# Multi-OS UI/UX backlog (Mac · iPhone · iPad · Watch)

Primary claim list for the **Shannon multi-OS UI/UX** 10‑minute loop.  
Each item is one pickable unit. Prefer **shared pure presenters** over copy-paste strings.

**Protocol**

1. Investigate: `./scripts/test_apple_platforms.sh --quick` when Xcode allows; note SKIP honestly.
2. Append 0–3 new items grounded in evidence (next free `UX-0xx`).
3. Implement **one** open item; mark `[x]` with Done; tests/builds for touched platforms green.
4. Cross-cutting non-UI work may still use `docs/ENHANCEMENT_BACKLOG.md` (ENH-018+).

**Verify**

- macOS: `cd Pill && swift test` / packages via `./scripts/test_apple_platforms.sh macos`
- Shared: `cd Packages/ShannonCore && swift test`
- Apps: see `docs/APPLE_PLATFORM_TESTING.md`

---

## P0 — parity & honesty

### - [ ] UX-001: Shared “needs you” / badge strings in ShannonCore for phone + pad + watch

- **Why:** Mac uses `AgentLiveSurfaceLogic.badgeLabel` / chrome; iPhone/iPad/Watch may hard-code “needs approval” / status labels → dual-OS wording drift.
- **Platforms:** macOS (reference), iOS, iPadOS, watchOS
- **Area:** `Packages/ShannonCore/`, `Pill/Sources/PillCore/AgentLiveSurface.swift`, phone/pad status views
- **First slice:** Export or mirror badge vocabulary in ShannonCore; one pure test; call from one mobile surface.
- **Priority:** P0

### - [ ] UX-002: Fail-closed empty states when CloudKit / hub offline (phone + pad)

- **Why:** Companions must not look “all quiet / healthy” when the Mac hub or sync is down; Mac already has hub offline copy.
- **Platforms:** iOS, iPadOS (watch relay secondary)
- **Area:** `iOS/Sources/ShannonPhone/`, `iPad/Sources/ShannonPad/ViewModels/AgentHubViewModel.swift`
- **First slice:** Single shared empty-state copy helper + pad or phone home empty view when no agents and sync offline.
- **Priority:** P0

### - [ ] UX-003: Approve/Deny primary action affordance parity (Mac ask card ↔ phone)

- **Why:** Gate asks must surface the prompt + approve/deny (or honest “open Mac”) on phone the same conceptual way as `GateAskCard` / `GateInlineCard`.
- **Platforms:** macOS, iOS
- **Area:** Phone confirmation UI, `ShannonCore` confirmation models, Mac `GateAskCard`
- **First slice:** Audit phone path vs Mac; fix missing disabled-state copy when gate unreachable.
- **Priority:** P0

---

## P1 — density & hierarchy

### - [ ] UX-004: iPad hub “needs you” sort matches Mac attention rank

- **Why:** Mac roster ranks needs-you → working → finished → idle; iPad card order may be insertion/updatedAt only.
- **Platforms:** iPadOS, macOS (reference)
- **Area:** `AgentHubViewModel`, shared rank helper from Core/PillCore
- **First slice:** Pure sort helper + unit test; wire pad list.
- **Priority:** P1

### - [ ] UX-005: Watch face shows primary focus line only when actionable

- **Why:** Mac collapsed pill stays quiet when idle (`Shannon · idle`); Watch should not invent busy chrome.
- **Platforms:** watchOS, macOS (reference)
- **Area:** `watchOS/Sources/ShannonWatch/`, shared focus string if available via sync snapshot
- **First slice:** Map synced attention → short line; idle → minimal face.
- **Priority:** P1

### - [ ] UX-006: Mac collapsed multi-agent density vs phone card list skim

- **Why:** Mac has multi-agent count + primary focus; phone list should skim same priority (needs-you first) without duplicating long task junk.
- **Platforms:** macOS, iOS
- **Area:** `PillView`, `HomeView` / agent cards
- **First slice:** Phone sort + badge using shared attention enum.
- **Priority:** P1

### - [ ] UX-007: Dynamic Type / Reduce Motion respect on pad hub and phone cards

- **Why:** Accessibility half-dead chrome is a UX defect; Mac already has Reduce Motion gates in places.
- **Platforms:** iOS, iPadOS
- **Area:** Card typography, animation on entropy sparks / companions
- **First slice:** One surface: disable nonessential animation when Reduce Motion is on; test if pure policy exists.
- **Priority:** P1

---

## P2 — polish & tooling

### - [ ] UX-008: Widget glance uses same relative-age buckets as Mac (no 1s thrash)

- **Why:** Mac uses signature age buckets to avoid layout thrash; widget may refresh too eagerly or show stale “now”.
- **Platforms:** iOS widget, macOS (reference)
- **Area:** `iOS/Sources/ShannonWidget/`, age helpers in Core
- **First slice:** Share bucketed age formatter; widget snapshot test or pure test.
- **Priority:** P2

### - [ ] UX-009: iPad compact (Slide Over) mode keeps needs-you agent reachable in one scroll

- **Why:** Compact layout is a first-class pad mode; needs-you buried below fold is a coordination failure.
- **Platforms:** iPadOS
- **Area:** `HubLayout`, `AgentHubView`, list order
- **First slice:** Pin needs-you section header or sticky top card when any pending ask.
- **Priority:** P2

### - [ ] UX-010: Document multi-OS status legend (amber ask vs red collapse) once

- **Why:** Mac has `PillChromePolicy.statusLegend`; phone/pad users need the same mental model in Settings or first-run.
- **Platforms:** all
- **Area:** docs + optional Settings blurb; `FirstRunCoach` patterns
- **First slice:** Short shared string in Core + show on phone empty/help.
- **Priority:** P2

---

## Investigation notes

- (Loop: dated “no new items” or findings here.)

## Related

- `docs/APPLE_PLATFORM_TESTING.md` · `scripts/test_apple_platforms.sh`
- `docs/ENHANCEMENT_BACKLOG.md` · `docs/PET_IMPLEMENTATION_BACKLOG.md`
- `docs/MULTI_DEVICE.md`
