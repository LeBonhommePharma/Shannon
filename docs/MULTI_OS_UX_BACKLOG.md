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

### - [x] UX-020: Watch empty list uses offline empty copy when phone unreachable

- **Why:** Watch empty list always `CompanionEmptyStateCopy.idleTitle`; never hub-offline when WC/phone unreachable.
- **Platforms:** watchOS
- **Area:** `WatchRootView`, `WatchModel` connectivity
- **First slice:** Map unreachable → `hubOfflineTitle` (or equivalent); idle only when connected + no agents.
- **Done:** `CompanionEmptyStateCopy.content(isPhoneReachable:)`; AgentList empty uses offline title/chip when `!isPhoneReachable`; pure + wiring tests.
- **Priority:** P2

### - [x] UX-021: Pad detail + notification panel disable Approve/Deny when hub offline

- **Why:** GateCard (UX-018) uses `companionAffordance`; `AgentDetailView` / `NotificationPanelView` still show live Approve/Deny when sync is down (VM refuse only — looks tappable).
- **Platforms:** iPadOS (iOS phone banner reference)
- **Area:** `AgentDetailView`, `NotificationPanelView`, `GateAskActionCopy`
- **First slice:** Wire both surfaces to `companionAffordance` + disable + status; pure wiring test.
- **Done:** Detail blockedPrompt + Notification ConfirmationRow use companionAffordance; hub passes lastError; Core wiring test.
- **Priority:** P1

### - [x] UX-022: Pad empty hub shows StatusLegendCopy (phone / Mac parity)

- **Why:** UX-010 put amber=approval · red=collapse on phone empty + Mac; pad `EmptyHubState` still omits `StatusLegendCopy` — dual mental-model gap.
- **Platforms:** iPadOS (iOS / macOS reference)
- **Area:** `DashboardGridView.EmptyHubState`, `StatusLegendCopy`
- **First slice:** Footer legend + a11y; pure wiring test forbids pad-only omission.
- **Done:** `EmptyHubState` footer + combined a11y; StatusLegendCopyTests pad wiring.
- **Priority:** P2

### - [x] UX-023: Watch face + gate delivery chrome share GateAskActionCopy tokens

- **Why:** Face `DeliveryRow` hard-coded “Sending answer… / Answer sent / Answer queued…” while gate `statusLine` used `GateAskActionCopy.sending` + dual sent/queued strings.
- **Platforms:** watchOS (Mac gate sending reference)
- **Area:** `ShannonFaceView.DeliveryRow`, `WatchRootView` statusLine, `GateAskActionCopy`
- **First slice:** Core `sent` / `queuedForPhone`; wire face + gate; pure wiring tests.
- **Done:** `GateAskActionCopy.sent` + `.queuedForPhone`; face + gate statusLine wired; dual hard-code tests.
- **Priority:** P2

### - [x] UX-024: Mac pill + watch face quiet titles use CompanionFocusCopy.quietShort

- **Why:** Pill `headerTitle` and watch `WatchScreen.face` title hard-coded `"Shannon"` while Core owns `quietShort` (complications / displayLine quiet path).
- **Platforms:** macOS, watchOS
- **Area:** `PillView.headerTitle`, `WatchModel.WatchScreen`, `CompanionFocusCopy`
- **First slice:** Return `quietShort`; pure wiring tests forbid dual literal.
- **Done:** Pill + WatchScreen face title → `CompanionFocusCopy.quietShort`; CompanionFocusCopyTests wiring.
- **Priority:** P2

### - [x] UX-025: Widget / complication / menu bar / phone brand chrome use quietShort

- **Why:** UX-024 closed pill + watch face titles; residual hard-coded `Text("Shannon")` / nav title on widget, complication, menu-bar popover, phone Home.
- **Platforms:** iOS widget, watchOS complication, macOS menu bar, iOS phone
- **Area:** `ShannonWidget`, `ShannonComplication`, `MenuBarPopoverView`, `HomeView`
- **First slice:** Wire brand chrome to `CompanionFocusCopy.quietShort`; pure multi-surface wiring test.
- **Done:** All four surfaces + a11y menu label; CompanionFocusCopyTests glance/menu wiring.
- **Priority:** P2

### - [x] UX-026: iPad hub brand chrome uses CompanionFocusCopy.quietShort

- **Why:** UX-025 closed phone/widget/menu brand chrome; pad compact nav title, sidebar title, and unknown-agent fallbacks still hard-coded `"Shannon"`.
- **Platforms:** iPadOS (iOS phone reference)
- **Area:** `AgentHubView`, `GateCardView`, `NotificationPanelView`, `CompanionFocusCopy`
- **First slice:** Wire nav titles + agent-name fallbacks to `quietShort`; pure pad wiring test.
- **Done:** Compact + sidebar `navigationTitle(quietShort)`; GateCard/Notification/a11y/activity fallbacks; CompanionFocusCopyTests pad hub wiring.
- **Priority:** P2

### - [x] UX-027: Mac menu-bar roster gate hint + status a11y use Core tokens

- **Why:** After gate/card Approve parity, menu-bar roster still hard-coded `"Gate · approve"` / `"Gate approve available"` and status-item symbol a11y hard-coded `"Shannon"`.
- **Platforms:** macOS (iOS/iPadOS/watch gate verb reference)
- **Area:** `MenuBarAgentRoster`, `MenuBarController`, `GateAskActionCopy`, `CompanionFocusCopy`
- **First slice:** Core `rosterApproveHint` / `rosterApproveAccessibility`; wire roster + quietShort a11y; pure wiring test.
- **Done:** GateAskActionCopy roster tokens; MenuBarAgentRoster + MenuBarController wired; GateAskActionCopyTests.
- **Priority:** P2

### - [x] UX-028: Mac ConfirmationPromptView Approve/Deny + shared head-gesture copy

- **Why:** Gate cards use `GateAskActionCopy` Approve/Deny; Mac `ConfirmationPromptView` still hard-coded Yes/No and dual `"Nod to confirm · shake to deny"` with phone.
- **Platforms:** macOS, iOS
- **Area:** `PillView.ConfirmationPromptView`, `HomeView` confirmation banner, `HeadGestureCopy`, `GateAskActionCopy`
- **First slice:** Core gesture tokens; wire Approve/Deny + hint on Mac + phone; pure wiring test.
- **Done:** `HeadGestureCopy` + ConfirmationPromptView Approve/Deny; phone Label; ConfirmationAndVoiceTests.
- **Priority:** P1

### - [x] UX-029: Pad + watch Now Playing idle share NowPlayingSnapshot.idleTitle

- **Why:** Pad `NowPlayingCardView` and watch media empty both hard-coded `"Nothing playing"` — dual empty-media chrome.
- **Platforms:** iPadOS, watchOS
- **Area:** `NowPlayingSnapshot`, `NowPlayingCardView`, `WatchRootView`
- **First slice:** Core `idleTitle` / `displayTitle`; wire pad + watch; pure wiring test.
- **Done:** `NowPlayingSnapshot.idleTitle` + `displayTitle`; pad/watch wired; PresentationTests.
- **Priority:** P2

### - [x] UX-030: Pad agent card + detail empty task share AgentState.displayTaskTitle

- **Why:** `AgentCardView` and `AgentDetailView` both hard-coded `"No task"` when `taskTitle` empty — dual empty-task chrome.
- **Platforms:** iPadOS (Core presenter for multi-OS reuse)
- **Area:** `AgentState`, `AgentCardView`, `AgentDetailView`
- **First slice:** Core `emptyTaskTitle` / `displayTaskTitle`; wire both pad surfaces; pure wiring test.
- **Done:** `AgentState.emptyTaskTitle` + `displayTaskTitle`; card + detail wired; PresentationTests.
- **Priority:** P2

### - [x] UX-031: Desktop companion a11y brand uses CompanionFocusCopy.quietShort

- **Why:** After menu-bar/status quietShort wiring (UX-025/027), desktop pet still hard-coded `"Open in Shannon"` / expand-hint brand.
- **Platforms:** macOS
- **Area:** `DesktopCompanionWindowController`, `CompanionFocusCopy`
- **First slice:** Wire a11y action + hint to `quietShort`; pure wiring test.
- **Done:** Desktop companion a11y action/hint; CompanionFocusCopyTests.
- **Priority:** P2

### - [x] UX-032: Widget empty docking uses DockingProgress.emptyGlance

- **Why:** Small widget hard-coded `"Idle"` when no docking run — residual empty-benchmark chrome (distinct from quiet brand face). Deferred across prior loops.
- **Platforms:** iOS widget (Core token for multi-OS reuse)
- **Area:** `DockingProgress`, `ShannonWidget`
- **First slice:** Core `emptyGlance`; wire widget; pure wiring test forbids dual `Text("Idle")`.
- **Done:** `DockingProgress.emptyGlance`; widget wired; PresentationTests.
- **Priority:** P2

### - [x] UX-033: Watch gate phone-away chip uses GateAskActionCopy.phoneAwayChip

- **Why:** Watch gate header hard-coded `"iPhone away"` while delivery status already uses `queuedForPhone` — phone-connectivity copy family split.
- **Platforms:** watchOS (Core token; Mac/phone delivery family reference)
- **Area:** `GateAskActionCopy`, `WatchRootView` gate header
- **First slice:** Core `phoneAwayChip`; wire gate Label; pure wiring test.
- **Done:** `GateAskActionCopy.phoneAwayChip`; watch gate wired; GateAskActionCopyTests.
- **Priority:** P2

### - [x] UX-034: Pad Gate Activity past-tense outcomes use GateAskActionCopy

- **Why:** Gate Activity rows hard-coded `"approved"` / `"denied"` while primary buttons use Approve/Deny — dual verb-family tokens.
- **Platforms:** iPadOS (Core token for multi-OS audit chrome)
- **Area:** `GateAskActionCopy`, `GateCardView.GateActivitySection`
- **First slice:** Core `outcomeApproved` / `outcomeDenied` / `outcomeLabel(approved:)`; wire activity row; pure wiring test.
- **Done:** Outcome tokens + `outcomeLabel`; GateActivitySection wired; GateAskActionCopyTests.
- **Priority:** P2

### - [x] UX-035: Phone reloads WidgetKit after SnapshotCache write

- **Why:** `PhoneModel.onSnapshot` saves App Group cache but never calls `WidgetCenter`; widget comment claims app reloads on every push — unimplemented. Watch reloads timelines after cache write; phone lock-screen lag can exceed MultiDeviceCadence (~15 min budget).
- **Platforms:** iOS (phone host + ShannonWidget)
- **Area:** `PhoneModel`, `ShannonWidget`, optional pet kind
- **First slice:** After successful `SnapshotCache.phone.save`, `WidgetCenter.shared.reloadTimelines(ofKind: "ShannonWidget")`; structural test forbids missing reload next to phone cache write.
- **Done:** PhoneModel gates reload on save success; ShannonWidget timeline comment fixed; MultiDeviceCadenceTests structural.
- **Priority:** P0

### - [x] UX-036: Menu-bar GateInlineCard uses macGateAffordance when hub socket down
- **Done:** GateInlineCard macGateAffordance + gateAvailable from popover; SessionUIWiringTests + GateAskActionCopyTests.

- **Why:** Notch `GateAskCard` disables Approve/Deny via `GateAskActionCopy.macGateAffordance`; menu-bar `GateInlineCard` always enables buttons when not resolving — fail-open vs UX-003 honesty bar.
- **Platforms:** macOS
- **Area:** `GateInlineCard`, `MenuBarPopoverView`, wiring tests
- **First slice:** Pass `gateAvailable`; disable + `statusMessage` from `macGateAffordance`; SessionUIWiringTests require affordance on GateInlineCard.
- **Priority:** P1

### - [x] UX-037: Phone head-gesture coaching only when motion actually armed
- **Done:** Arm only when isAvailable; banner availableHint vs unavailableLine; ConfirmationAndVoiceTests wiring.

- **Why:** Banner shows `HeadGestureCopy.availableHint` from `isAwaitingConfirmation` alone; `HeadGestureListener.arm` no-ops when unavailable/denied without UI — fail-open “Nod to confirm” while motion off.
- **Platforms:** iOS
- **Area:** `PhoneModel.updateGestureArming`, `ConfirmationBanner`, `HeadGestureListener`, `HeadGestureCopy`
- **First slice:** Arm only when available; show `availableHint` only when armed else `unavailableLine`; pure/wiring tests.
- **Priority:** P1

### - [x] UX-038: Widget glance fail-closed when hub/sync offline
- **Done:** SnapshotCacheRecord envelope lastError; onSyncFailure rewrite; widget offline Core copy; SecurityTests + CompanionEmptyStateCopyTests.

- **Why:** Store refresh errors set `lastError` without rewriting cache; widget has no offline branch / Core offline chip — glance can stay “agents running / Idle docking” after hub down (pairs with UX-035 reload).
- **Platforms:** iOS widget (+ phone cache writer)
- **Area:** `SnapshotCache` metadata or offline flag, `ShannonWidget`, `CompanionEmptyStateCopy`
- **First slice:** Persist offline signal with cache; widget empty/offline uses Core offline family; presence test.
- **Priority:** P1

### - [x] UX-039: Pad non-empty hub shows offline chip; SyncIndicator not healthy under lastError
- **Done:** AgentHubView offline chip + SyncIndicator lastError path; CompanionEmptyStateCopyTests pad wiring; ipad build green.

- **Why:** Phone shows `DisconnectedPill` when content + `lastError`; pad only fail-closes empty roster. Toolbar `SyncIndicator` still shows relative age after prior success while offline — opposite of fail-closed chrome.
- **Platforms:** iPadOS (iOS DisconnectedPill reference)
- **Area:** `AgentHubView`, `SyncIndicator`, `CompanionEmptyStateCopy.offlineChip`
- **First slice:** Offline chip when `lastError != nil` and snapshot non-empty; SyncIndicator prefers offline glyph under lastError; wiring test.
- **Priority:** P1

### - [x] UX-040: Watch gate “Gate 1 of N” counts active (non-expired) confirmations only
- **Done:** GateApprovalView pendingCount → GlobalNotifyResponse.activePending; GlobalNotifyResponseTests.

- **Why:** `GateApprovalView.pendingCount` uses all `confirmations.count` while face/complication/Core filter expired — overstates backlog vs answerable asks.
- **Platforms:** watchOS
- **Area:** `WatchRootView.GateApprovalView`, `GlobalNotifyResponse.activePending`
- **First slice:** Active-only count for header; wiring test forbids bare `.confirmations.count` for gate chrome.
- **Priority:** P1

### - [x] UX-041: Watch complication getSnapshot must not invent busy placeholder metrics
- **Done:** getSnapshot cache miss → ShannonSnapshot(); placeholder gallery-only; CompanionFocusCopyTests wiring.

- **Why:** Timeline falls back to empty snapshot; `getSnapshot` falls back to busy FlexAID∆S + docking 78/85 + H 0.61 — invents metrics when cache nil (gallery/cold stack).
- **Platforms:** watchOS complication
- **Area:** `ShannonComplication.ComplicationProvider.getSnapshot`
- **First slice:** `load() ?? ShannonSnapshot()` for snapshot path; keep `placeholder(in:)` sample-only; test/comment contract.
- **Priority:** P1

### - [x] UX-042: Unify Mac hub-offline resolve error with GateAskActionCopy.macGateOffline

- **Done:** AgentActivity.describe socketUnavailable → GateAskActionCopy.macGateOffline; pure dual-literal forbidden.
- **Why:** Pre-disable copy `macGateOffline` vs post-tap `AgentActivity.describe` socketUnavailable string — same meaning, two shipping strings.
- **Platforms:** macOS
- **Area:** `AgentActivity.describe`, `GateAskActionCopy`
- **First slice:** Map socketUnavailable → shared Core token; pure test forbids dual literal.
- **Done:** `describeResolveError(.socketUnavailable)` → `GateAskActionCopy.macGateOffline`; pure + structural tests; remote-answer path asserts same token.
- **Priority:** P2

### - [x] UX-043: Roster Gate · approve hint requires gateAvailable
- **Done:** SessionContentCard.gateAvailable + showsApproveHint; MenuBarAgentRoster wires activity.gateAvailable; offline+pending unit test.

- **Why:** `showsApproveHint` is needsYou+ask only; comment claims no invent when hub offline but no `gateAvailable` input — menu roster still claims answerability offline.
- **Platforms:** macOS
- **Area:** `SessionContentPresenter`, `MenuBarAgentRoster`
- **First slice:** Thread gateAvailable; `showsApproveHint = canAnswerInline && gateAvailable`; pure unit test offline + pending → no hint.
- **Priority:** P2

### - [x] UX-044: AirPods answer TTS uses GateAskActionCopy outcome family
- **Done:** PhoneModel.answer AirPods TTS → outcomeLabel; GateAskActionCopyTests forbid Confirmed/Denied.

- **Why:** `PhoneModel.answer` announces hard-coded `"Confirmed"` / `"Denied"` while banner uses Approve/Deny and Core outcomes are approved/denied — third dual on answer path.
- **Platforms:** iOS
- **Area:** `PhoneModel.answer`, `GateAskActionCopy`
- **First slice:** Spoken outcome tokens (or reuse approve/deny); forbid literal Confirmed/Denied in phone answer path.
- **Priority:** P2

### - [x] UX-045: Mic double-tap hands-free toggle actually works (or drop claim)
- **Done:** MicButton double-tap toggleHandsFreeDictation; VoiceDictation hands-free path; ConfirmationAndVoiceTests.

- **Why:** MicButton docs claim double-tap hands-free; only long-press implemented; `VoiceDictation.isHandsFree` never set true under iOS/.
- **Platforms:** iOS
- **Area:** `MicButton`, `VoiceDictation`
- **First slice:** Wire double-tap toggle + second-tap finish, or remove claim and dead branch.
- **Priority:** P2

### - [x] UX-046: Hide HostCapacity cards on full empty/offline phone home
- **Done:** HomeView HostCapacity only when !snapshot.isEmpty; HostCapacityCompanionPresenceTests.

- **Why:** Empty offline still always paints Mac + iPhone capacity cards (local Nominal thermal) under EmptyStateView — undercuts UX-002 fail-closed empty tone.
- **Platforms:** iOS
- **Area:** `HomeView` layout vs `CompanionEmptyStateCopy`
- **First slice:** When `snapshot.isEmpty`, hide capacity (or Mac-only when device nil); keep when non-empty.
- **Priority:** P2

### - [x] UX-047: Pad docking Cancel/Export not silent no-ops
- **Done:** Docking cancel/export hub.post not-wired-yet; Dashboard/Detail wired; GateAskActionCopyTests pad docking.

- **Why:** `DockingProgressView` offers Cancel Run / Export CSV but dashboard/detail pass empty closures — looks live, does nothing (unlike honest “not wired yet” benchmark request).
- **Platforms:** iPadOS
- **Area:** `DockingProgressView`, `DashboardGridView`, `DockingDetailView`
- **First slice:** Hide until RemoteCommand exists, or wire honest hub.post status; no fake success.
- **Priority:** P2

### - [x] UX-048: Pad ⌘A/⌘D disabled when companionAffordance cannot interact
- **Done:** canInteractWithOldestPending; ⌘A/⌘D + palette disabled offline; wiring tests.

- **Why:** GateCard/detail honor offline disable; Confirmation menu only disables when pending empty — offline + open ask still shows live keyboard Approve/Deny.
- **Platforms:** iPadOS
- **Area:** `ShannonPadApp` command menu, `GateAskActionCopy.companionAffordance`
- **First slice:** Disable when pending empty or `!canInteract`; share helper with palette if convenient.
- **Priority:** P2

### - [x] UX-049: Pad notification “Needs You” uses HubCompactNeedsYouChrome.sectionTitle
- **Done:** NotificationPanelView → HubCompactNeedsYouChrome.sectionTitle; HubCompactNeedsYouChromeTests.

- **Why:** Compact pin uses shared section title; NotificationPanel hard-codes same string — dual token ownership.
- **Platforms:** iPadOS
- **Area:** `NotificationPanelView`, `HubCompactNeedsYouChrome`
- **First slice:** Replace literal; wiring test.
- **Priority:** P2

### - [x] UX-050: Watch notifications empty fail-closed when phone unreachable
- **Done:** NotificationListView offline via CompanionEmptyStateCopy when !isPhoneReachable; wiring test.

- **Why:** Agent empty list uses CompanionEmptyStateCopy offline path; notifications empty always `"No notifications"` — healthy quiet when WC phone away.
- **Platforms:** watchOS
- **Area:** `WatchRootView.NotificationListView`, `CompanionEmptyStateCopy`
- **First slice:** When empty && !isPhoneReachable show offline title/chip; reachable keeps idle empty; wiring test.
- **Priority:** P2

### - [x] UX-051: Watch rectangular complication “Shannon asks” shares Core gate glance token
- **Done:** gateGlanceTitle/Header Core tokens; rectangular complication wired; GateAskActionCopyTests.

- **Why:** Hard-coded `"Shannon asks"` / N-count while face uses CompanionFocusCopy / AgentAttentionCopy needs-you vocabulary — watch-internal dual.
- **Platforms:** watchOS complication
- **Area:** `ShannonComplication.rectangular`, optional Core glance header token
- **First slice:** Core compact gate-glance title; wire rectangular header; forbid dual hard-coded Shannon asks.
- **Priority:** P2

### - [x] UX-052: Pad clipboard task uses AgentState.displayTaskTitle
- **Done:** copyToClipboard uses displayTaskTitle; PresentationTests path check.

- **Why:** Card/detail use displayTaskTitle (UX-030); `copyToClipboard` still interpolates raw `taskTitle` so empty pastes blank vs UI “No task”.
- **Platforms:** iPadOS
- **Area:** `DashboardGridView.copyToClipboard`
- **First slice:** Use displayTaskTitle; extend presentation path check if desired.
- **Priority:** P3

---

## Investigation notes

- **2026-07-26 (P2/P3 parallel wave):** Five agents closed **UX-042…052**, **ENH-024/025**, PET **E6/E7**. ShannonCore 275 green; apple --quick on commit path.
- **2026-07-26 (loop 31):** `--quick` all PASS (ran=4). No open P0/P1 (swarm closed UX-035…041). Claimed **UX-042** (P2): post-tap socketUnavailable → `macGateOffline`. Considered already-queued: UX-043 roster gateAvailable; UX-044 AirPods Confirmed/Denied; UX-050 watch “No notifications”; pad “No matches” surface-specific (leave). **No additional UX-0xx**.
- **2026-07-26 (P0/P1 parallel agents):** Implemented **UX-035…041** + **ENH-023** via five background agents (phone WidgetKit/gesture/offline, Mac clearAsk, GateInlineCard, pad offline chip, watch gate count + complication). ShannonCore 261 + Pill CloudPublisher/SessionUIWiring green; apple --quick re-run on commit path.
- **2026-07-26 (loop 30):** `--quick` all PASS. Open P0 **UX-035** (phone WidgetKit reload after SnapshotCache) claimed. Closed with PhoneModel + structural test. Next open: **UX-036** GateInlineCard macGateAffordance (P1). Considered: UX-037 gesture arm honesty; UX-038 widget offline; watch No notifications (P2+). **No additional UX-0xx**.
- **2026-07-26 (Grok 4.5 OS swarm):** Four background audits (`swarm_{macos,ios,ipados,watchos}.md`) + `./scripts/test_apple_platforms.sh --quick` **PASS** (ran=4 failed=0). Enqueued **UX-035…052** (18 open), plus ENH-023…025 and PET **E6/E7** on sibling queues. Per-OS enqueue: macOS 3 UX + 1 ENH; iOS 6 UX + 2 ENH + 1 PET; iPadOS 6 UX + 1 PET (F1+F2 merged; comment-only 20s dropped); watchOS 4 UX. Dropped: companion bubble character empty, status-item spoken brand prose, palette/No matches surface-specific, watch face quiet-offline P3 polish, configurationDisplayName catalog.
- **2026-07-26 (loop 29):** `--quick` all PASS. Backlog empty after UX-033. Residual pad Gate Activity dual approved/denied past tense. Claimed **UX-034**. Considered: watch `"No notifications"` empty (surface-specific); watch crown coaching prose (gesture narrative); pad `"No matches"`; `configurationDisplayName` catalog (leave). **No additional UX-0xx**.
- **2026-07-26 (loop 28):** `--quick` all PASS. Backlog empty after UX-032. Residual watch gate dual `"iPhone away"` vs `queuedForPhone` family. Claimed **UX-033**. Considered: watch `"No notifications"` empty (surface-specific); pad gate activity approved/denied past tense (optional); pad `"No matches"`; `configurationDisplayName` catalog (leave). **No additional UX-0xx**.
- **2026-07-26 (loop 27):** `--quick` all PASS. Backlog empty after UX-031. Residual widget docking empty `"Idle"` (deferred many loops). Claimed **UX-032**. Considered: watch `"No notifications"` / `"iPhone away"` (surface-specific); pad palette `"No matches"`; gate activity lowercase approved/denied (audit narrative, not primary verbs); `configurationDisplayName` catalog (leave). **No additional UX-0xx**.
- **2026-07-26 (loop 26):** `--quick` all PASS. Backlog empty after UX-030. Residual desktop companion dual brand a11y. Claimed **UX-031**. Considered: widget docking `"Idle"` (leave); watch `"No notifications"` / `"iPhone away"` (surface-specific); pad `"No matches"` palette (surface-specific). **No additional UX-0xx**.
- **2026-07-26 (loop 25):** `--quick` all PASS. Backlog empty after UX-029. Residual pad dual `"No task"` on card + detail. Claimed **UX-030**. Considered: widget docking `"Idle"` (leave); desktop `"Open in Shannon"` a11y brand (optional); watch `"No notifications"` / `"iPhone away"` (surface-specific). **No additional UX-0xx**.
- **2026-07-26 (loop 24):** `--quick` all PASS. Backlog empty after UX-028. Residual pad/watch dual `"Nothing playing"`. Claimed **UX-029**. Considered: widget docking `"Idle"` (leave); desktop `"Open in Shannon"` a11y brand (optional); watch `"No notifications"` / `"iPhone away"` (surface-specific). **No additional UX-0xx**.
- **2026-07-26 (loop 23):** `--quick` all PASS. Backlog empty after UX-027. Residual Mac ConfirmationPrompt Yes/No vs gate Approve/Deny + dual gesture coaching. Claimed **UX-028**. Considered: widget docking `"Idle"` (leave); pad/watch `"Nothing playing"` dual (optional); desktop `"Open in Shannon"` a11y brand (optional). **No additional UX-0xx**.
- **2026-07-26 (loop 22):** `--quick` all PASS. Backlog empty after UX-026. Residual Mac menu-bar `"Gate · approve"` dual + status-item a11y `"Shannon"`. Claimed **UX-027**. Considered: widget docking `"Idle"` (not brand/gate); `configurationDisplayName` catalog (leave); theme preview product chrome OK; phone head-gesture “Nod to confirm” (gesture copy, not primary Approve verb). **No additional UX-0xx**.
- **2026-07-26 (loop 21):** `--quick` all PASS. Backlog empty after UX-025. Residual pad hub brand `"Shannon"` nav titles + unknown-agent fallbacks. Claimed **UX-026**. Considered: widget docking `"Idle"` (not brand); widget/complication `configurationDisplayName` (system catalog — leave); theme preview product chrome OK; Mac menu-bar symbol a11y `"Shannon"` (status item, not nav brand). **No additional UX-0xx**.
- **2026-07-26 (loop 20):** `--quick` all PASS. Backlog empty; residual brand `"Shannon"` on widget/complication/menu/phone. Claimed **UX-025**. Considered: widget docking `"Idle"` (not brand token — leave); theme preview + Settings titles OK product chrome. **No additional UX-0xx**.
- **2026-07-26 (loop 19):** `--quick` all PASS. Backlog empty; Mac/watch dual quiet `"Shannon"`. Claimed **UX-024**. Considered: widget `"Idle"` docking-empty (different context — not quiet brand token); pad feed empty prose OK. **No additional UX-0xx**.
- **2026-07-26 (loop 18):** `--quick` all PASS. Backlog empty; watch face vs gate delivery dual strings. Claimed **UX-023**. Considered: widget `"Idle"` docking-empty (different context); PillView header `"Shannon"` quietShort (optional); pad notification empty prose OK. **No additional UX-0xx**.
- **2026-07-26 (loop 17):** `--quick` all PASS. Backlog empty; pad empty missing StatusLegend. Claimed **UX-022**. Considered: widget `"Idle"` docking-empty (different context); watch face `"Sending answer…"` delivery narrative vs `GateAskActionCopy.sending`; PillView header `"Shannon"` quietShort family (optional). **No additional UX-0xx**.
- **2026-07-26 (loop 16):** `--quick` all PASS. Backlog empty; residual pad detail/notification live Approve offline. Claimed **UX-021**. Considered: widget `"Idle"` docking-empty (different context); watch `"iPhone away"` gate chip (status narrative, not empty-roster dual); pad StatusLegend on empty (optional polish). **No additional UX-0xx**.
- **2026-07-26 (loop 15):** `--quick` all PASS. Claimed P2 **UX-020** (watch offline empty). Considered: multi-OS dual primary verbs clean; backlog empty after this claim. **No new UX-0xx**.
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
