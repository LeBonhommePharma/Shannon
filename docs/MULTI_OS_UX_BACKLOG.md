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

### - [x] UX-001: Shared “needs you” / badge strings in ShannonCore for phone + pad + watch

- **Why:** Mac uses `AgentLiveSurfaceLogic.badgeLabel` / chrome; iPhone/iPad/Watch may hard-code “needs approval” / status labels → dual-OS wording drift.
- **Platforms:** macOS (reference), iOS, iPadOS, watchOS
- **Area:** `Packages/ShannonCore/`, `Pill/Sources/PillCore/AgentLiveSurface.swift`, phone/pad status views
- **First slice:** Export or mirror badge vocabulary in ShannonCore; one pure test; call from one mobile surface.
- **Done:** `AgentAttentionCopy` in ShannonCore (badge/focus/notify tokens); PillCore `badgeLabel` delegates; pad `AgentActivity.label` + detail blocked headline; phone `AgentCard` + watch agent list badges; GlobalNotify uses shared notify/focus; wiring test forbids "Waiting on you" forks.
- **Priority:** P0

### - [x] UX-002: Fail-closed empty states when CloudKit / hub offline (phone + pad)

- **Why:** Companions must not look “all quiet / healthy” when the Mac hub or sync is down; Mac already has hub offline copy.
- **Platforms:** iOS, iPadOS (watch relay secondary)
- **Area:** `iOS/Sources/ShannonPhone/`, `iPad/Sources/ShannonPad/ViewModels/AgentHubViewModel.swift`
- **First slice:** Single shared empty-state copy helper + pad or phone home empty view when no agents and sync offline.
- **Done:** `CompanionEmptyStateCopy` in ShannonCore (idle vs hub offline titles/detail/chip/symbol); phone `EmptyStateView` + `DisconnectedPill` + pad `EmptyHubState` wired; orphan pad centre column passes `lastError`; pure + wiring tests.
- **Priority:** P0

### - [x] UX-003: Approve/Deny primary action affordance parity (Mac ask card ↔ phone)

- **Why:** Gate asks must surface the prompt + approve/deny (or honest “open Mac”) on phone the same conceptual way as `GateAskCard` / `GateInlineCard`.
- **Platforms:** macOS, iOS
- **Area:** Phone confirmation UI, `ShannonCore` confirmation models, Mac `GateAskCard`
- **First slice:** Audit phone path vs Mac; fix missing disabled-state copy when gate unreachable.
- **Done:** `GateAskActionCopy` (Approve/Deny verbs + companion/mac offline affordances); phone banner disables + status when hub offline/expired (no more dual-OS “Confirm”); Mac `GateAskCard` uses shared offline/action copy; pure + wiring tests.
- **Priority:** P0

---

## P1 — density & hierarchy

### - [x] UX-004: iPad hub “needs you” sort matches Mac attention rank

- **Why:** Mac roster ranks needs-you → working → finished → idle; iPad card order may be insertion/updatedAt only.
- **Platforms:** iPadOS, macOS (reference)
- **Area:** `AgentHubViewModel`, shared rank helper from Core/PillCore
- **First slice:** Pure sort helper + unit test; wire pad list.
- **Done:** `AgentAttentionRank` + `rankedForDisplay(pendingAgentIDs:)` + `ShannonSnapshot.agentsRankedForDisplay()` (needs-you elevates open confirmations); pad `visibleAgents`, phone list, watch face/list/complication wired; pure tests for Mac-parity order.
- **Priority:** P1

### - [x] UX-005: Watch face shows primary focus line only when actionable

- **Why:** Mac collapsed pill stays quiet when idle (`Shannon · idle`); Watch should not invent busy chrome.
- **Platforms:** watchOS, macOS (reference)
- **Area:** `watchOS/Sources/ShannonWatch/`, shared focus string if available via sync snapshot
- **First slice:** Map synced attention → short line; idle → minimal face.
- **Done:** `CompanionFocusCopy` (actionable filter + primaryFocusLine + quiet tokens); snapshot `complicationLine` / face use it; idle agents no longer invent busy chrome; Always-On / quiet face show `Shannon · idle`; pure + wiring tests.
- **Priority:** P1

### - [x] UX-006: Mac collapsed multi-agent density vs phone card list skim

- **Why:** Mac has multi-agent count + primary focus; phone list should skim same priority (needs-you first) without duplicating long task junk.
- **Platforms:** macOS, iOS
- **Area:** `PillView`, `HomeView` / agent cards
- **First slice:** Phone sort + badge using shared attention enum.
- **Done:** `AgentListSkim` in ShannonCore (active fleet count Mac parity, multi-agent count label, clipped skim line, ranked rows with pending→needs-you badge); phone HomeView fleet chip + `AgentCard(row:)` one-line skim; pure + wiring tests.
- **Priority:** P1

### - [x] UX-007: Dynamic Type / Reduce Motion respect on pad hub and phone cards

- **Why:** Accessibility half-dead chrome is a UX defect; Mac already has Reduce Motion gates in places.
- **Platforms:** iOS, iPadOS
- **Area:** Card typography, animation on entropy sparks / companions
- **First slice:** One surface: disable nonessential animation when Reduce Motion is on; test if pure policy exists.
- **Done:** `MotionChromePolicy` in ShannonCore (`allowsForeverPulse` / `shouldPulseRunningDot` / `allowsIdleCompanionMotion`); pad `PulseIfRunning` + phone `AgentCard` running-dot pulse gated; pad `PetRailView` idle wobble frozen under Reduce Motion; pure + wiring tests.
- **Priority:** P1

---

## P2 — polish & tooling

### - [x] UX-008: Widget glance uses same relative-age buckets as Mac (no 1s thrash)

- **Why:** Mac uses signature age buckets to avoid layout thrash; widget may refresh too eagerly or show stale “now”.
- **Platforms:** iOS widget, macOS (reference)
- **Area:** `iOS/Sources/ShannonWidget/`, age helpers in Core
- **First slice:** Share bucketed age formatter; widget snapshot test or pure test.
- **Done:** `SharedRelativeAge` in ShannonCore (15 s `bucketed` = Mac `signatureAge`; `fine` for live UI); widget small/rect glance age via `glanceBucketed`; pure + wiring tests.
- **Priority:** P2

### - [x] UX-009: iPad compact (Slide Over) mode keeps needs-you agent reachable in one scroll

- **Why:** Compact layout is a first-class pad mode; needs-you buried below fold is a coordination failure.
- **Platforms:** iPadOS
- **Area:** `HubLayout`, `AgentHubView`, list order
- **First slice:** Pin needs-you section header or sticky top card when any pending ask.
- **Done:** `HubCompactNeedsYouChrome.shouldPin` pure policy + `partitionForDisplay`; compact hub elevates needs-you band (header + agents) above docking; `HubLayout.isCompact`; pure + structural wiring tests.
- **Priority:** P2

### - [x] UX-010: Document multi-OS status legend (amber ask vs red collapse) once

- **Why:** Mac has `PillChromePolicy.statusLegend`; phone/pad users need the same mental model in Settings or first-run.
- **Platforms:** all
- **Area:** docs + optional Settings blurb; `FirstRunCoach` patterns
- **First slice:** Short shared string in Core + show on phone empty/help.
- **Done:** `StatusLegendCopy` in ShannonCore (amber=approval · red=collapse); Mac `PillChromePolicy.statusLegend` delegates; phone `EmptyStateView` footer; pure + wiring tests.
- **Priority:** P2

### - [x] UX-011: Mac signatureAge delegates to SharedRelativeAge (no dual bucket math)

- **Why:** UX-008 put 15 s buckets in Core for widgets, but Mac `AgentActivitySnapshot.signatureAge` still reimplemented the same math — drift risk.
- **Platforms:** macOS, iOS widget (reference)
- **Area:** `Pill/Sources/PillCore/AgentActivity.swift`, `Packages/ShannonCore/SharedRelativeAge.swift`
- **First slice:** `signatureAge` / `age` → `SharedRelativeAge.bucketed` / `.fine`; existing Mac age tests green.
- **Done:** PillCore `signatureAge` + `age` call Core; iPad UX-009 multi-statement `dashboard` explicit `return` (compile fix).
- **Priority:** P2

### - [x] UX-012: Pad Confirm buttons use GateAskActionCopy.approve (Mac/phone parity)

- **Why:** Phone uses Approve via `GateAskActionCopy`; iPad detail / notification panel / palette still say “Confirm”.
- **Platforms:** iPadOS, iOS (reference)
- **Area:** `AgentDetailView`, `NotificationPanelView`, `PaletteCatalogue`
- **First slice:** Replace hard-coded Confirm labels with `GateAskActionCopy.approve`; pure wiring test.
- **Done:** Detail / notification / GateCard / palette use `GateAskActionCopy.approve` + `.deny`; wiring test forbids pad `"Confirm"`.
- **Priority:** P2

### - [x] UX-013: Mac GateInlineCard shares GateAskActionCopy with GateAskCard

- **Why:** Menu-bar popover still hard-coded “needs approval” / Approve / Deny while notch `GateAskCard` uses Core tokens → dual Mac wording drift.
- **Platforms:** macOS
- **Area:** `Pill/Sources/ShannonPill/GateInlineCard.swift`, `GateAskActionCopy`
- **First slice:** Wire capsule + buttons + a11y to `GateAskActionCopy`; pure wiring test.
- **Done:** `GateInlineCard` uses `needsApproval` / `approve` / `deny` / `sending`; Core wiring test forbids hard-coded capsule string.
- **Priority:** P2

### - [x] UX-014: Watch gate + empty agent list use shared Core copy

- **Why:** Watch hard-coded Approve/Deny/Sending and “No agents” while phone/pad/Mac use `GateAskActionCopy` / `CompanionEmptyStateCopy`.
- **Platforms:** watchOS (macOS/iOS/iPadOS reference)
- **Area:** `watchOS/Sources/ShannonWatch/WatchRootView.swift`
- **First slice:** Wire gate buttons + sending line + empty list to Core tokens; pure wiring test.
- **Done:** Gate `approve`/`deny`/`sending` + empty list `CompanionEmptyStateCopy.idleTitle`; wiring test forbids hard-coded Approve/Deny/No agents.
- **Priority:** P2

### - [x] UX-015: Mac empty roster title uses CompanionEmptyStateCopy.idleTitle

- **Why:** Watch/phone/pad empty idle titles call Core; Mac notch `emptyBoard` still hard-codes `"No agents running"` and menu-bar roster uses dual `"No agents."` — token drift risk.
- **Platforms:** macOS (iOS/iPadOS/watchOS reference)
- **Area:** `Pill/Sources/ShannonPill/PillView.swift`, `MenuBarAgentRoster.swift`
- **First slice:** Wire both empty titles to `CompanionEmptyStateCopy.idleTitle`; pure wiring test forbids hard-coded dual strings.
- **Done:** `emptyBoard` + menu-bar empty roster use `CompanionEmptyStateCopy.idleTitle`; Core + SessionUIWiring tests forbid dual hard-codes.
- **Priority:** P2

### - [x] UX-016: Mac macOS 14+ CompanionBoardView shows session meta + usage

- **Why:** Expanded board on modern Mac uses `CompanionBoardView` only; meta/usage lived on `#else agentRow` — dead density path for host OS 14+ (AgentPeek-class session density).
- **Platforms:** macOS (primary expanded HUD)
- **Area:** `PetPillView.swift` (`CompanionRow`/`CompanionBoardView`), `SessionContentPresenter.companionBoardDensity*`, `PillView.agentBoard`
- **First slice:** Pure density map from sessions/listedSurfaces; pass into board; render fail-closed; tests prove UI consumes density.
- **Done:** `CompanionBoardDensity` + `companionBoardDensity(from:)` / `companionBoardDensityByAgent`; row shows meta + usage; PillView passes `densityByAgent` from `listedAgentSurfaces`; pure + structural tests.
- **Priority:** P0

### - [x] UX-017: Mac collapsed quiet idle uses CompanionFocusCopy.quietFace

- **Why:** Watch face uses Core `CompanionFocusCopy.quietFace` (`"Shannon · idle"`); Mac `SessionContentPresenter.collapsedStatusLine` hard-codes the same string — dual token drift risk.
- **Platforms:** macOS (watchOS reference)
- **Area:** `Pill/Sources/PillCore/SessionContentPresenter.swift`, `CompanionFocusCopy`
- **First slice:** Return `CompanionFocusCopy.quietFace` on quiet path; pure tests assert Core token; wiring test forbids hard-coded literal in presenter.
- **Done:** `collapsedStatusLine` quiet path → `CompanionFocusCopy.quietFace`; Core + SessionUIWiring + presenter tests forbid dual literal.
- **Priority:** P2

---

### - [x] UX-018: iPad GateCard disables Approve/Deny when hub/sync offline

- **Why:** Phone uses `companionAffordance` / disables when `lastError`; pad `GateCardView` keeps Approve/Deny live on error — multi-OS honesty drift.
- **Platforms:** iPadOS (iOS reference)
- **Area:** `iPad/.../GateCardView.swift`, `AgentHubViewModel.lastError`, `GateAskActionCopy`
- **First slice:** Disable buttons + status line when lastError / hub offline; pure wiring or ViewModel policy test.
- **Done:** GateCardView `companionAffordance` + disabled buttons/status; hub `answer` / `answerPendingConfirmation` fail-closed; Core wiring test.
- **Priority:** P1

### - [x] UX-019: Pad + watch badges elevate open pending confirmation

- **Why:** Open confirmation can still badge as “working” if activity is mid-task; Mac attention elevates needs-you.
- **Platforms:** iPadOS, watchOS (macOS reference)
- **Area:** pad `AgentActivity.label`, watch `badgeLabel(for:)`
- **First slice:** Pass `hasPendingConfirmation` into badge; pure test with pending id set.
- **Done:** Pad `label/tint/dotState(hasPendingConfirmation:)` + card/sidebar/palette; watch list `badgeLabel(..., hasPendingConfirmation:)`; pure + wiring tests.
- **Priority:** P1

### - [ ] UX-020: Watch empty list uses offline empty copy when phone unreachable

- **Why:** Watch empty list always `CompanionEmptyStateCopy.idleTitle`; never hub-offline when WC/phone unreachable.
- **Platforms:** watchOS
- **Area:** `WatchRootView`, `WatchModel` connectivity
- **First slice:** Map unreachable → `hubOfflineTitle` (or equivalent); idle only when connected + no agents.
- **Priority:** P2

---

## Investigation notes

- **2026-07-26 (loop 14):** `--quick` all PASS. Claimed P1 **UX-019** (pad/watch pending badge elevate). Considered: UX-020 watch offline empty; residual dual primary verbs clean. **No new UX-0xx**.
- **2026-07-26 (loop 13):** `--quick` all PASS. Open P1 **UX-018** claimed (pad GateCard offline). Considered: UX-019 pending badge elevate; UX-020 watch offline empty; residual detail/notification buttons inherit VM guard. **No new UX-0xx**.
- **2026-07-26 (swarm multi-device):** Exploration swarm + host audit. Filed **UX-018…020** (pad/watch honesty). Dual primary-verb strings clean. Builds green unsigned.
- **2026-07-26 (loop 12):** `--quick` all PASS. Backlog empty after UX-016. Residual dual quiet idle: Mac collapsedStatusLine hard-codes `"Shannon · idle"`. Claimed **UX-017**. Considered: widget `"Idle"` docking-empty (different context); PillView fallback `"Shannon"` quietShort family (optional follow-up); dual Approve/empty/status legend closed. **No additional UX-0xx**.
- **2026-07-26 (multi-OS optimize):** UX-001…015 closed. Residual skeptic gap: macOS 14+ CompanionBoard density dead vs listedSurfaces/agentRow. Claimed **UX-016**. Dual-copy primary verbs clean after UX-014/015. **No additional UX-0xx** this fire pending multi-platform re-check.
- **2026-07-26 (loop 11):** `--quick` all PASS. Backlog empty; residual dual empty idle title on Mac pill + menu-bar. Claimed **UX-015**. Considered: SessionContentPresenter hard-coded `"Shannon · idle"` vs `CompanionFocusCopy.quietFace` (follow-up, not this fire); widget `"Idle"` docking-empty (different context); watch delivery prose (OK). **No additional UX-0xx**.
- **2026-07-26 (loop 10):** `--quick` all PASS. Backlog empty; watch gate/empty dual wording. Claimed **UX-014**. Considered: face “Sending answer…” delivery prose (OK as status narrative, not primary verb); Mac “No agents running” already matches Core idleTitle. **No additional UX-0xx**.
- **2026-07-26 (loop 9):** `--quick` all PASS. Backlog empty; residual dual wording on Mac `GateInlineCard`. Claimed **UX-013**. Considered: no other grounded dual-string forks in shipped surfaces. **No additional UX-0xx**.
- **2026-07-26 (loop 8):** `--quick` ios/ipad/watch PASS; macOS FAIL (pet prefs WIP). Claimed **UX-012** (pad Confirm→Approve). Considered: GateInlineCard hard-coded needs approval → optional follow-up; no new P0. **No new UX-0xx**.
- **2026-07-26 (loop 7):** `--quick` macOS FAIL (pet `moodDisplayWord` WIP — not multi-OS UX claim); iPad FAIL (UX-009 `dashboard` missing `return` on multi-statement `some View`). Claimed **UX-011** residual (Mac age → SharedRelativeAge) + iPad compile fix. Considered: pad Confirm verb → **UX-012**; GateInlineCard hard-code needs approval → covered by GateAskActionCopy if wired later. **No third item.**
- **2026-07-26 (loop 6):** `--quick` failed (missing `AgentListSkim` while phone required it). Residual **UX-006** shipped: Core skim + phone fleet chip/rows. Next open **UX-008**. **No new UX-0xx**.
- **2026-07-26 (loop 5):** `--quick` all PASS. Claimed **UX-005** (watch primary focus only when actionable). Considered: phone skim (UX-006), Reduce Motion (UX-007), widget age buckets (UX-008). **No new UX-0xx**.
- **2026-07-26 (loop 4):** `--quick` all PASS. Claimed **UX-004** (needs-you rank Mac parity). Considered: watch idle face (UX-005), phone skim (UX-006, ranking now shared), Reduce Motion (UX-007). **No new UX-0xx**.
- **2026-07-26 (loop 3):** `--quick` all PASS. Claimed **UX-003** (Approve/Deny + disabled hub-offline copy). Considered: pad attention rank (UX-004), watch idle face (UX-005), Reduce Motion (UX-007). **No new UX-0xx**.
- **2026-07-26 (loop 2):** `--quick` all PASS. Claimed **UX-002** (shared fail-closed empty states). Considered: Confirm/Approve verb (UX-003), pad rank (UX-004), watch idle focus (UX-005). **No new UX-0xx**.
- **2026-07-26 (loop):** `./scripts/test_apple_platforms.sh --quick` — macOS/iOS/iPad/watch builds green (unsigned). UX-001 residual dual wording closed (pad detail + phone/watch badges). Considered for new items: empty-state dual copy (phone “Can't reach iCloud” vs pad “Not syncing…”) → already **UX-002**; Confirm vs Approve verb drift → **UX-003**; pad sort vs Mac rank → **UX-004**. **No new UX-0xx** this fire.


## Related

- `docs/APPLE_PLATFORM_TESTING.md` · `scripts/test_apple_platforms.sh`
- `docs/ENHANCEMENT_BACKLOG.md` · `docs/PET_IMPLEMENTATION_BACKLOG.md`
- `docs/MULTI_DEVICE.md`
