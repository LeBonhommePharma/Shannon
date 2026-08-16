# Shannon enhancement / optimization backlog

Open work units for a follow-up Grok Build (or human) session.  
**Claim one implement item per ~10‑minute loop.** Investigation may **append** new items first.

**How to use (implementation loop)**

1. **Investigate** (optional every fire): run a health sample; add 0–3 new open items grounded in tests/warnings/code (next free `ENH-0xx` id). Pets go in `docs/PET_IMPLEMENTATION_BACKLOG.md`.
2. Pick the first unchecked high-priority item still open (or any P0 first).
3. Implement only that item; leave others untouched.
4. Mark `- [x]` when done and tests for that area stay green.
5. Prefer pure logic + unit tests; no invented telemetry/tokens/H.

Original seed: 2026-07-26 thorough test pass (Pill session-content / live-surface).  
**ENH-001–017 closed.** New work continues from **ENH-018**.

## Investigation notes

- **2026-07-26 (P2/P3 parallel wave):** Closed ENH-024/025 with phone agents.
- **2026-07-26 (P0/P1 parallel agents):** Closed **ENH-023** remote clearAsk fail-open via activity.resolve parity.
- 2026-07-26 15:40 — health sample: Pill SessionContent|AgentLiveSurface|Pet|Companion 180 passed; hub `test_pet_*.py` 114 passed. ENH-001–017 closed. No new ENH items (no dual-HUD gaps / Sendable warnings / fail-closed regressions observed this pass).

---

## P0 — correctness / dual-HUD risk

### - [x] ENH-001: Include gate activity in `SharedTelemetrySnapshot`

- **Why:** `SharedTelemetryBinding.primaryFocus` / `agentViews` call `AgentLiveSurfaceLogic` with **empty** `activity: []`, so multi-consumer identity tests and any future shared HUD path cannot agree with the live pill on tool lines (working “Editing …”). Pill + menu bar already pass `recentActivity` directly; the *shared* snapshot path is incomplete.
- **Area:** `Pill/Sources/PillCore/SharedTelemetryBinding.swift`, `AgentActivityMonitor` capture site, `SharedTelemetryBindingTests`
- **First slice:** Add `recentActivity: [GateDBReader.ActivityEvent]` to the snapshot; wire capture; pass into `resolve` / `primaryFocus`; extend agreement tests with a tool_call fixture.
- **Done:** Snapshot + capture carry `recentActivity`; `agentViews`/`primaryFocus`/`displayEqual` use it; tool_call + republish tests added.
- **Priority:** P0

### - [x] ENH-002: Fix Swift 6 `Sendable` capture warning in `ParityPanelModel.refresh`

- **Why:** `Task.detached { [weak self] in … await MainActor.run { guard let self } }` warns *“reference to captured var 'self' in concurrently-executing code”* (will be an error in Swift 6). Pill build is green today only because this is a warning.
- **Area:** `Pill/Sources/ShannonPill/PanelSectionRegistry.swift`
- **First slice:** Capture `self` strongly on MainActor after hop, or use a non-mutating payload apply without re-binding `self` as `var`; confirm `swift build` is warning-free for that file.
- **Done:** Added `@MainActor applyParityPayload(_:)` and hop via `await self?.applyParityPayload(payload)` (no `var self` in concurrent code).
- **Priority:** P0

---

## P1 — session content / AgentNotch parity density

### - [x] ENH-003: Merge gate + artifact sessions into roster `sessionsByAgent`

- **Why:** Menu-bar roster meta (project / branch / model) only comes from `parity.sessions`, which **filters to `.artifact`**. Live gate agents with cwd/task from the hub never get meta chips even when an artifact row exists under a different merge key, and gate-only fields are dropped.
- **Area:** `Pill/Sources/ShannonPill/MenuBarPopoverView.swift`, `PanelSectionRegistry.swift` (`collectParityPayload`), optional `SessionMerge`
- **First slice:** Build `sessionsByAgent` from **all** merged sessions (gate + artifact), not artifact-only; keep Pulled sessions section artifact-focused if desired; unit-test merge prefer rules for meta fill.
- **Done:** `SessionMerge.prefer` always fills meta from loser; `byAgentId` + `ParityPayload.sessionsByAgent`; Pulled stays artifact-only.
- **Priority:** P1

### - [x] ENH-004: Parse Claude Code / Codex token usage when present on disk

- **Why:** `AgentSession.tokensIn/Out` and `UsageCore` exist, but readers never populate tokens. Collapsed usage chips stay empty even when JSONL/rollouts contain usage events. Fail-closed still applies when absent.
- **Area:** `Pill/Sources/AgentReaders/ClaudeCodeSessionReader.swift`, `CodexSessionReader.swift`, `UsageCore/` (replace stub), fixture tests under `Pill/Tests/PillCoreTests/`
- **First slice:** Extract input/output tokens from known event shapes only; map to `AgentSession`; assert fixture file with tokens → non-nil usage; empty fixture → nil.
- **Done:** Readers populate `tokensIn`/`tokensOut` from Claude `message.usage` (sum input+cache keys) and Codex `token_count.total_token_usage` (plain `input_tokens` only); UsageCore stub left for ENH-014; fixtures+tests for usage and fail-closed nil.
- **Priority:** P1

### - [x] ENH-005: Deduplicate agent roster vs pulled-sessions double listing

- **Why:** The same logical agent can appear in **Active now** (gate live) and **Pulled sessions** (disk), with different attention badges — glanceable fleet becomes noisy.
- **Area:** `MenuBarAgentRoster`, `PulledSessionsSection`, `SessionContentPresenter`
- **First slice:** When an agent id is already on the live roster, either hide the pulled row or fold disk meta into the roster card only; pure helper + unit test.
- **Done:** `sessionsExcludingLiveAgents` + `cards(… liveAgentIds:)`; Pulled section hides ids already on live summary; meta still on roster via ENH-003.
- **Priority:** P1

### - [x] ENH-006: Surface pending ask prompt on roster rows when `canAnswerInline`

- **Why:** Cards already carry `pendingPrompt` / `canAnswerInline`, but menu-bar rows only show badge + activity line — AgentNotch peeks show the approval text before expand.
- **Area:** `MenuBarAgentRoster.swift`, optional second line styling
- **First slice:** If `card.needsYou`, show truncated `pendingPrompt` (or activity line already shortened from prompt — verify) with Approve deep-link only if gate available; no fake buttons when hub offline.
- **Done:** `SessionContentCard.rosterDetailLine` prefers shortened `pendingPrompt` when `needsYou`; falls back to `activityLine`; `showsApproveHint` == `canAnswerInline` (text “Gate · approve”, no fake buttons). Menu-bar roster + a11y wired; pure unit tests.
- **Priority:** P1

---

## P1 — performance / poll path

### - [x] ENH-007: Avoid double-resolve in `rankedAgents` + UI row surfaces

- **Why:** `rankedAgents` builds a full `fleet` (resolve per agent), then UI often `resolve`s again per row for badge/detail. On a 1.5s poll with many agents this is pure CPU on MainActor-adjacent paths.
- **Area:** `AgentLiveSurface.swift`, `PillView`, `MenuBarAgentRoster` / `SessionContentPresenter.cardsFromAgents`
- **First slice:** Return `[(AgentActivitySnapshot, AgentLiveSurface)]` or cache surface by agent id for one tick; unit test identity of attention vs current API.
- **Done:** `rankedAgentSurfaces` one resolve/tick; `rankedAgents` maps it; `cardsFromAgents` uses pairs (session usage merged once). **Follow-up:** PillView `listedAgentSurfaces` passes surface into agent rows + entropy rails (no per-row re-resolve).
- **Priority:** P1

### - [x] ENH-008: Cap artifact reader I/O when parity panel is closed

- **Why:** `ParityPanelModel.refresh` scans Claude/Codex trees every 2s while the popover may be closed (if callers refresh aggressively). Expensive on large `~/.claude/projects`.
- **Area:** `MenuBarController` / popover open path, `ParityPanelModel`
- **First slice:** Only force artifact scan when popover opens or on a longer interval (e.g. 15s); keep gate agents cheap path; test refresh throttle pure if extracted.
- **Done:** `ParityRefreshPolicy` (open 2s + artifacts / closed 15s gate-only / force full); `panelVisible` from popover appear/disappear; pure `ParityRefreshPolicyTests`.
- **Priority:** P1

---

## P2 — test / DX / ops

### - [x] ENH-009: Document / wire `PYTHONPATH=python` for `tests/python/`

- **Why:** Bare `pytest tests/python/` fails collection with `ModuleNotFoundError: No module named 'shannon'` unless `PYTHONPATH=python` or `pip install -e .`. Hub tests do not need this. CI and local DX diverge.
- **Area:** `docs/` or `pytest.ini` / `pyproject.toml` pythonpath, `CLAUDE.md` Testing section
- **First slice:** Add `pythonpath = ["python"]` (or equivalent) so default pytest works; re-run `pytest tests/python/ -q`.
- **Done:** `tool.pytest.ini_options.pythonpath = ["python"]` in pyproject.toml; `tests/python/conftest.py` prepends `python/` to `PYTHONPATH` for subprocess CLI tests; CLAUDE.md Testing notes updated; bare `pytest tests/python/ -q` → 180 passed, 51 skipped.
- **Priority:** P2

### - [x] ENH-010: Fix ShannonPill / PillCore class duplication in installed app probe

- **Why:** `./scripts/shannon probe` loads `/Applications/Shannon.app` and logs many *“Class … implemented in both PillCore.framework and ShannonPill”* warnings. Spurious cast risk for production install.
- **Area:** `scripts/package_pill.sh`, Xcode / SPM linking, app bundle layout
- **First slice:** Ensure PillCore is linked once (framework OR static into executable, not both); re-run probe without duplicate-class lines.
- **Done:** Strategy A — ShannonPill links ShannonCore/Theme only via embedded `PillCore.framework` (`@_exported` in `ModuleExports.swift`); removed direct package deps that dual-linked into the executable. Also added static AgentReaders/DevServers/Routes to XcodeGen so Xcode builds match SPM modules. `package_pill.sh` auto prefers SwiftPM first. Probe *“implemented in both”*: 11 → 0 (Xcode Debug app + SPM `make_app`).
- **Priority:** P2

### - [x] ENH-011: Mute `var s` / unused-mutation warnings in AgentLiveChromeTests

- **Why:** `testIdleBadgeSaysLive` used `var s` never mutated — noise in every ShannonPill test build.
- **Area:** `Pill/Tests/ShannonPillTests/AgentLiveChromeTests.swift`
- **Done:** Changed to `let` during thorough test pass (still green).
- **Priority:** P2 (polish)

### - [x] ENH-012: Pure unit test for `collapsedUsageChip` multi-agent ranking

- **Why:** Usage chip follows `primarySurface` (needs-you first). When needs-you agent has no usage but a working agent has ctx%, chip is nil — may be intentional; pin the product choice with a test so UI density does not regress silently.
- **Area:** `SessionContentPresenterTests`
- **First slice:** Fixture needs-you without usage + working with contextPercent → assert chip nil or document “prefer primary only” in comment + assert.
- **Done:** Documented primary-only on `collapsedUsageChip`; test asserts nil when needs-you has no usage + working has ctx 47%; control asserts primary's own ctx% shows.
- **Priority:** P2

---

## P2 — product extensions (keep fail-closed)

### - [x] ENH-013: Branch field from git in session readers when cwd known

- **Why:** AgentNotch shows branch; Shannon has `AgentSession.branch` but readers rarely set it. A best-effort `git -C cwd rev-parse --abbrev-ref HEAD` (timeout, fail-closed) would unlock meta chips without inventing data.
- **Area:** `AgentReaders/`, optional shared `GitBranchProbe` pure helper
- **First slice:** Injectable runner for tests; nil on failure; never block MainActor — call from detached parity collect only.
- **Done:** `GitBranchProbe` (injectable runner, timeout ~0.75s, reject empty/`HEAD`); Claude + Codex readers fill `AgentSession.branch` via `resolveBranch` with per-cwd cache; pure unit tests, no real git required.
- **Priority:** P2

### - [x] ENH-014: Replace `UsageCoreStub` with real provider-agnostic usage model

- **Why:** Package target is an empty stub (`moduleName` only). Session usage is ad hoc on `AgentSession` tokens. A small `UsageSnapshot` bridge shared by readers + gate keeps one type.
- **Area:** `Pill/Sources/UsageCore/`, `SessionContentPresenter.usageFromSession`
- **First slice:** Move `AgentUsageSnapshot` or a typealias into UsageCore; wire one reader; leave others nil.
- **Done:** `UsageSnapshot` + `UsageBridge` in UsageCore; PillCore `typealias AgentUsageSnapshot`; Claude reader `usageSnapshot`; presenter delegates; Codex still via session tokens only.
- **Priority:** P2

### - [x] ENH-015: Collapsed multi-agent label “N agents” like AgentNotch marketing

- **Why:** Shannon shows a numeric capsule when `collapsedActiveCount > 1` but the primary line is still a single agent focus. Optional: when count > 1 and no needs-you, primary line could be `3 agents · Editing…` (still one focus agent for the tool line).
- **Area:** `SessionContentPresenter.collapsedStatusLine`, `PillView`
- **First slice:** Pure string builder + tests; only when count > 1 and attention is working/finished (never invent).
- **Done:** `collapsedStatusLine` / `multiAgentCollapsedLabel` prefix `"N agents · \(activityLine)"` when activeCount > 1 and primary is working/finished with a real activity fragment; needs-you and single-agent lines unchanged. PillView still uses presenter API.
- **Priority:** P2

---

## P3 — low priority / polish

### - [x] ENH-016: Companion board ordering vs `rankedAgents` alignment

- **Why:** `CompanionRoster` uses mood/waiting heuristics; board listing uses `rankedAgents`. Usually aligned for needs-you, but finished-vs-working edge cases can reorder pets vs status rows.
- **Area:** `PetCompanion.swift` `CompanionRoster.build`, `PillView.listedAgents`
- **First slice:** Sort companions by the same attention rank helper; one pure test.
- **Done:** `CompanionRoster.build` orders via `AgentLiveSurfaceLogic.rankedAgents`; tests pin id order == rankedAgents (incl. working before finished).
- **Priority:** P3

### - [x] ENH-017: Hub gate: emit structured tool kind on activity rows

- **Why:** Pill classifies tools from free-text blobs (`toolKindFromBlob`). Structured `tool` / `kind` columns from the gate would reduce misclassification (edit vs shell).
- **Area:** `hub/shannon_gate.py`, `GateDBReader.ActivityEvent`, `AgentLiveSurfaceLogic.classifyTool`
- **First slice:** Optional column; reader maps if present else legacy blob; tests both paths.
- **Done:** `agent_activity.tool_kind` (migrate + CREATE); `log_activity_event(..., tool_kind=)`; Pill `ActivityEvent.toolKind` + classifyTool prefers structured kind, falls back to blob.
- **Priority:** P3

### - [x] ENH-018: Harden multi-device sync contracts (swarm 2026-07-26)

- **Why:** Swarm audit found private-DB security theater, missing confirmation overwrite / stale-boundary tests, `consumeCommands` double-exec on failed delete, capacity serialization fixture gap.
- **Area:** `ShannonStore.consumeCommands`, `SecurityTests`, `SyncBehaviourTests`, `SerializationTests`, `PresentationTests`
- **First slice:** Delete-before-return for commands; read real ShannonSync source for private DB; overwrite + boundary + capacity round-trip tests.
- **Done:** `consumeCommands` only returns after successful delete; SecurityTests reads `ShannonSync.swift`; confirmation overwrite + delete-fail + 60s boundary + MacDeviceState capacity round-trip tests green.
- **Priority:** P1

### - [x] ENH-019: Publish docking / notifications / timers from Mac hub (or document “not mirrored”)

- **Why:** `MULTI_DEVICE.md` + `ShannonStore.refresh` list `DockingProgress` / `NotificationMirror` / `TimerState`, but `CloudPublisher.publish` only mirrors media / device / one agent / confirmations — consumers may expect empty forever.
- **Area:** `Pill/Sources/ShannonPill/CloudPublishing.swift`, store refresh, docs
- **First slice:** Either wire sources + publish each type with pure tests, **or** document “not mirrored yet” in MULTI_DEVICE.md and stop implying full record matrix.
- **Priority:** P1
- **Done:** Documented path — MULTI_DEVICE.md honesty section (schema vs Mac publisher); `CloudPublishing.publish` comment lists published vs not (docking / notifications / timers). Full publish wiring deferred.

### - [x] ENH-020: Multi-agent `AgentState` roster publish (fail-closed entropy)

- **Why:** `agentSnapshot()` publishes a single ShannonBridge aggregate; multi-agent Mac fleet is not mirrored as `AgentState` rows (confirmations are multi-agent only).
- **Area:** `CloudPublishing.agentSnapshot`, activity roster, `AgentState`
- **First slice:** Publish one `AgentState` per live agent id from activity summary; entropy only when measured; retract exited agents; pure publisher test with InMemory backend.
- **Done:** `AgentStateRosterPublish` pure builder + `CloudPublisher` multi-agent publish/retract (`publishedAgentIDs`); fail-closed via `resolveForAgent` / `.measured` only; bridge-only fallback when roster empty. Tests: `AgentStateRosterPublishTests`, `CloudPublisherRosterIntegrationTests` (+ existing provenance suite green).
- **Priority:** P1

### - [x] ENH-021: Wire or demote `PetCloudRecord`

- **Why:** Serialize-only CloudSyncable-ish pet path exists without `allRecordTypes` / publisher / store consume — dead multi-device surface.
- **Area:** pet cloud types, `ShannonSyncConfig.allRecordTypes`
- **First slice:** Either register + publish/merge with tests, or remove/mark internal and drop false CloudSyncable surface.
- **Done:** Demoted honesty: `PetCloudRecord` / `ShannonPet` docs state local-only (not hub-published, not in `allRecordTypes`); serialization kept for tests/future; pure test asserts `PetCloudRecord.recordType` absent from `ShannonSyncConfig.allRecordTypes`; `MULTI_DEVICE.md` notes not hub-published.
- **Priority:** P2

### - [x] ENH-022: Align publisher entropy path with local `EntropyProvenance.resolve`

- **Why:** Local UI may show gate-measured H while publisher only uses bridge `isMeasured` — devices stay fail-closed (good) but Mac vs phone diverge when demo bridge + real gate coexist.
- **Area:** `CloudPublishing.agentSnapshot`, `EntropyProvenance`
- **First slice:** Document divergence or share one resolve for publish; test demo+gate never publishes collapse as measured.
- **Priority:** P2
- **Done:** Fleet `bridgeAggregate` uses `EntropyProvenance.resolve` (bridge → gate → absent) with `activity.agentEntropy`; multi-agent rows keep `resolveForAgent` + gate map. Demo collapse never published; gate-measured H publishes when resolve falls through. Tests in `CloudPublisherProvenanceTests` (demo+gate, multi-agent resolveForAgent).

### - [x] ENH-023: Remote companion answer must not clearAsk when gate resolve fails

- **Why:** `CloudPublishing.applyRemoteAnswer` always `clearAsk` after `try? resolveAsync`, swallowing errors — local `AgentActivity.resolve` only clears on success. Phone/watch can retract CloudKit while Mac pill stops pulsing though agent remains blocked at dead socket.
- **Area:** `Pill/Sources/ShannonPill/CloudPublishing.swift` `applyRemoteAnswer`, `GateApprovalClient`, optional `lastResolveError` surface
- **First slice:** `clearAsk` only after successful resolve; on failure keep ask + visible error; unit/integration test with failing socket path.
- **Done:** `applyRemoteAnswer` → `activity.resolve` (same terminal as local); clearAsk only on success; `CloudPublisherRemoteAnswerTests`.
- **Priority:** P0

### - [x] ENH-024: AirPods tertiary stem dismiss notifications is real or removed

- **Why:** `PhoneModel.handleStemPress` tertiary → `dismissAllNotifications()` only fires haptics — no notification mutation or Mac retract. Mapping claims dismiss effect.
- **Area:** `iOS/Sources/ShannonPhone/PhoneModel.swift`, notification mirror if retract needed
- **First slice:** Optimistic local dismiss + optional retract, or remove tertiary mapping until real.
- **Priority:** P3

### - [x] ENH-025: Phone freeform voice: implement Mac query transport or drop claim

- **Why:** `PhoneModel.handle` freeform / non-awaiting confirm is haptic-only with comment “Mac owns interpretation”; no CloudKit freeform/`RemoteCommand` path. Dead promise.
- **Area:** `PhoneModel.handle`, `ShannonStore.send`, optional Core command type, Mac consumer
- **First slice:** Document honest no-op **or** minimal freeform RemoteCommand + Mac consume; show previewCommand if kept.
- **Priority:** P3

### - [x] ENH-026: Multi-provider usage windows when source provides them (parity G1)

- **Why:** AgentNotch/Peek surface plan/context windows (5h/7d, monthly) when readable; Shannon `UsageSnapshot` is fail-closed but thin — no honest multi-window presentation when gate/artifacts already expose window fields.
- **Area:** `UsageCore` / `UsageSnapshot`, session presenters, collapsed usage chip
- **First slice:** Inventory which readers already carry window/limit fields; extend `UsageSnapshot` only for real fields; pure tests forbid inventing totals.
- **Done:** Inventory: Codex `token_count.rate_limits` (primary 300m / secondary 10080m + `used_percent` + `resets_at` + `plan_type`) on disk; ClaudeUsage local API shape documented in pure parser (no network). `UsageWindow` + `UsageSnapshot.windows`; `UsageBridge.windowsFromCodexRateLimits` / `windowFromProvider` never invent % from tokens; `AgentSession.usageWindows` + presenter `usageFromSession` → chip `5h 26% · 7d 94%`; Codex reader + fixture; pure + artifact tests.
- **Priority:** P2
- **Parity:** AgentPeek usage / AgentNotch plan gauge (candidate G1)

### - [x] ENH-027: Expand works-with session readers for high-value local agents (parity G2)

- **Why:** AgentPeek lists ~25 brands; Shannon ships Claude Code, Codex, Cursor, Cowork, Kimi. Category present; residual brands with local disk/process signals remain uncovered.
- **Area:** `Pill/Sources/AgentReaders/`, `PanelSectionRegistry`, TerminalAgentProbe
- **First slice:** Add 1–2 readers with fixtures where local session paths exist; fail-closed empty roots; pure parse tests.
- **Priority:** P2
- **Parity:** AgentPeek agent matrix / AgentNotch works-with (candidate G2)
- **Done:** OpenCode (`~/.local/share/opencode/opencode.db` SQLite + pure `sessionFromRow`) and Gemini CLI (`~/.gemini/tmp/*/chats/session-*.jsonl` + `.project_root`); fail-closed missing roots; fixtures + tests; `PanelSectionRegistry` registration; TerminalAgentProbe `opencode` only (gate-valid). No invented sessions/tokens.

### - [x] ENH-028: Jump-to-host-terminal for live session (parity G3)

- **Why:** Competitors “jump” to the session host; Shannon can expand/focus pill row but does not consistently activate the terminal app/window for known cwd/host.
- **Area:** Pill focus/handoff, TerminalAgentProbe host map, `NSWorkspace` activation
- **First slice:** When host process + cwd known, activate host or open cwd; pure policy + one integration smoke path.
- **Priority:** P2
- **Parity:** AgentNotch jump / AgentCallout jump (candidate G3)
- **Done:** `HostTerminalJumpPolicy` + `HostTerminalJumpInput` pure decide (running attachBundle → hostTerminal label→bundle map → live attachPid → real directory cwd; fail-closed `.none`); `HostTerminalJumpExecutor` NSWorkspace activate/open; context menus on CompanionBoard / agentRow / menu-bar roster + jump button on pulled sessions; `HostTerminalJumpPolicyTests` matrix + SessionUIWiring structural needles.

### - [x] ENH-029: Open terminal workspace action from routes (parity G7)

- **Why:** AgentPeek “Views” open a terminal workspace; Shannon has QuickRoutes/FastActions but no dedicated open-workspace action at project cwd.
- **Area:** `Pill/Sources/Routes/`, terminal launcher helper
- **First slice:** One action “Open Terminal here” for selected session cwd; structural wiring test.
- **Priority:** P3
- **Parity:** AgentPeek Views (candidate G7)
- **Done:** `OpenTerminalHerePolicy` + `OpenTerminalHereInput` pure decide (existing directory cwd required; preferred attach bundle → hostTerminal label→bundle → `com.apple.Terminal`; fail-closed `.none`); `OpenTerminalHereExecutor` NSWorkspace open-dir-with-terminal; terminal button on pulled sessions + context menus on CompanionBoard / menu-bar roster; `OpenTerminalHereTests` matrix + SessionUIWiring structural needles. Never invents cwd.

### - [x] ENH-030: Mac voice callout on completion / needs-you (parity G8)

- **Why:** AgentCallout’s defining feature is spoken callouts; Shannon has phone AirPods announce on ask but no Mac multi-agent completion/needs-you voice product.
- **Area:** Pill notification path, `NSSpeechSynthesizer` or AVSpeech, preferences mute
- **First slice:** One system voice on needs-you or task_complete when pref enabled; pure “should announce” policy tests; no invent content.
- **Priority:** P2
- **Parity:** AgentCallout voice (candidate G8)
- **Done:** `VoiceCalloutPolicy` pure shouldAnnounce/spokenText/decide (pref off / mute / Focus → never; needs-you uses `AgentAttentionCopy.needsYouNotifyTitle`; task_complete `"name done"` only with real agent id); explicit completion event types only (no label invent); baseline on first poll so history is silent; `MacVoiceCallout` + `SystemSpeechSynthesizer` (AVSpeech); pref `voiceCalloutsEnabled` default **off** + Settings toggle; `AgentActivityMonitor` wires needs-you + new task_complete; `VoiceCalloutPolicyTests` matrix.

### - [x] ENH-031: Gate ask surfaces change paths/summary when payload has them (parity G9)

- **Why:** AgentCallout shows diffs/paths on approve; Shannon gate shows prompt text only — partial when ask payload already includes paths/files.
- **Area:** GateDB ask model, `GateAskCard` / `GateInlineCard`, presenters
- **First slice:** If payload has path list, show clipped paths under prompt; pure formatter tests; no fake diffs.
- **Priority:** P2
- **Parity:** AgentCallout diff review (candidate G9)
- **Done:** `GateAskChangePaths` pure extract/present (real keys only: `paths`/`files`/scalars + `change_summary` family; clip + overflow; never invent from prose). `PendingAsk.changePaths`/`changeSummary` + `changePathsPresentation`; GateDBReader attributes from matching `agent_messages.payload_json` only (interaction_id match; fail-closed empty). Mac `GateAskCard` + `GateInlineCard` show clipped block under prompt when present. Pure + DB + SessionUIWiring tests. No fake diffs.

### - [x] ENH-032: Always Allow only when hub policy supports sticky approve (parity G10)

- **Why:** AgentPeek offers Always Allow when supported; Shannon is Approve/Deny only — may be intentional safety, but gap is real if gate protocol already has sticky modes.
- **Area:** hub gate protocol, `GateApprovalClient`, Mac gate cards
- **First slice:** Audit protocol for sticky approve; if present, wire opt-in UI + tests; if absent, document fail-closed “not supported” and close as N/A.
- **Priority:** P3
- **Parity:** AgentPeek Always Allow (candidate G10)
- **Done (Branch B — fail-closed N/A):** Audit: hub `approval_response` + `resolve_interaction(id, approved: bool)` are binary only; no sticky/always/session scope on wire or DB. `GateStickyApprovePolicy` pure helper (`hubProtocolSupportsStickyApprove = false`; `showsAlwaysAllow` requires hub support **and** explicit offer; never invents from prose). UI remains Approve/Deny only — Mac `GateAskCard`/`GateInlineCard` must not hard-code Always Allow. `GateApprovalClient.approvalPayload` stays binary (tests forbid sticky keys). Pure + structural + client shape tests. Re-open as Branch A only when hub grows a sticking sticky mode.

---

## Investigation notes

- **2026-08-16 (C++20→C++26):** Audited `src/shannon/**`, `CMakeLists.txt` (`CMAKE_CXX_STANDARD 20`), CI `g++-13`. g++-13 has no `-std=c++26`; C++23 library on that compiler has `expected`/`move_only_function`/`unreachable` but not `print`/`simd`. `std::simd` math (`exp`) is still missing in GCC 16 libstdc++ — Shannon’s custom `simd_exp.hpp` stays. Plan: `docs/CXX_MODERNIZATION.md`. Enqueued **ENH-033…036**. Do not flip the dialect in one PR.
- **2026-07-26 (AgentNotch/Peek/Callout parity):** Sources https://www.agentnotch.app · https://agentpeek.app/ · https://agentcallout.com/. User approved G1–G4,G6–G10 (not G5 chat, not G11 OTEL). Enqueued **ENH-026…032** + UX-057/058. Inventory: `{SCRATCH}/parity_inventory.md`. Counts: present 17 / partial 8 / missing 5 (C1–C30).
- **2026-07-26 (Grok 4.5 OS swarm):** macOS audit filed **ENH-023** (remote clearAsk fail-open). iOS filed **ENH-024** (stem dismiss no-op) and **ENH-025** (freeform dead). Cross-check: not ENH-018…022 (closed multi-device honesty). UI dual-copy/gate chrome → `docs/MULTI_OS_UX_BACKLOG.md` UX-035…052.

### - [x] ENH-033: C++20 constexpr Backend name table (no dialect bump)

- **Why:** `DispatchTelemetry::summary` and `UnifiedDispatch::backend_name` hand-roll the same `switch (Backend)`. A new enumerant can silently print `"UNKNOWN"` / fall through. First slice of `docs/CXX_MODERNIZATION.md` Phase A — smallest C++ surface, no ISA files.
- **Area:** `src/shannon/types.hpp`, `src/shannon/unified_dispatch.cpp`, `tests/cpp/test_shannon_v2.cpp`
- **First slice:** `constexpr` name table covering `SCALAR`…`NEON`+`AUTO`; exhaustive switch with fail-closed default; unit test every enumerant. Do **not** change `Backend` integer values.
- **Done:** `shannon::backend_name` constexpr exhaustive switch in `types.hpp`; `UnifiedDispatch::backend_name` delegates; `DispatchTelemetry::summary` uses `std::format`; `kAllBackends` / `kConcreteBackends` tables. GoogleTest covers every enumerant + corrupt `99 → UNKNOWN`. Integer values unchanged.
- **Priority:** P2

### - [x] ENH-034: Span-primary entropy kernel ABI + nullptr guards

- **Why:** Public kernels take `const double*, size_t`; `nullptr` with `n>0` is UB (audit). `std::span` overloads already exist as wrappers in the other direction.
- **Area:** `src/shannon/entropy.hpp`, `src/shannon.hpp`, `unified_dispatch.cpp`, `tests/cpp/test_shannon_v2.cpp`
- **First slice:** Span as the declared API; pointer+size becomes an inline span wrapper that rejects `nullptr && n>0`; GoogleTest for empty / null / n==1. No SIMD rewrite in this item.
- **Done:** Span is the declared kernel ABI in `entropy.hpp` / v1 `shannon.hpp`; pointer+size is an inline wrapper via `detail::as_span` (never constructs a non-empty span from nullptr). Dispatch returns `INVALID_ARGS` for `nullptr && n > 0`. Tests: `ScalarEntropy.NullptrNonzeroIsZero`, `SpanOverload`, `UnifiedDispatch.NullptrNonzeroIsInvalidArgs`. ISA-traits rewrite remains ENH-035.
- **Priority:** P2

### - [x] ENH-035: ISA-traits log-sum-exp (one algorithm, thin ISA TUs)

- **Why:** Scalar / OMP / SSE4.2 / AVX2 / AVX-512 / NEON duplicate the same H formula. A traits template is the prerequisite for a later `std::simd` backend; doing `std::simd` first would fork a seventh copy. Custom `simd_exp.hpp` must stay — C++26 `[simd.math]` is not available.
- **Area:** new `src/shannon/entropy_algorithm.hpp`, `src/shannon/entropy_*.cpp`, `src/shannon/simd_exp.hpp`
- **First slice:** One configurational-entropy algorithm over a vector traits type; convert AVX2 only; bit-identical vs current AVX2 tests. Follow-up PRs for AVX-512 / NEON / SSE — do not land all ISAs in one loop.
- **Done:** `configurational_entropy` / `entropy_from_probs` / `entropy_from_logprobs` templates in `entropy_algorithm.hpp`. Thin TUs: scalar (width=1), SSE4.2 (configurational; libm exp; mul+add), AVX2, AVX-512, NEON. OpenMP stays a reduction specialization (same finite-support max). Finite-only max + `select_finite` so masked `-inf` logits do not 0·(-inf) NaN into H=0. Tests: `Avx2Kernels.*`, `Sse42Kernels.*`, `Avx512Kernels.*` (CI `-E Avx512`), `NeonKernels.*`, `Entropy.NegInfMaskedLogitsUseFiniteSupport`.
- **Priority:** P1
- **Plan:** `docs/CXX_MODERNIZATION.md` Phase A.2 then Phase C

### - [x] ENH-036: CI compiler floor for C++23 (g++-14/15), then `std::expected` façade

- **Why:** g++-13 (the old CI pin) does not accept `-std=c++26` and lacks `<print>` / `std::simd`. C++23 `std::expected` / `std::unreachable` / `std::to_underlying` exist on g++-13 `-std=c++23`, but a dialect bump still needs a CMake option and `setup.py` `/std:c++23` so wheels keep a C++20 escape hatch.
- **Area:** `.github/workflows/ci.yml`, `CMakeLists.txt`, `setup.py`, then `src/shannon/types.hpp` / `unified_dispatch.*`
- **First slice:** compiler bump + `SHANNON_CXX_STANDARD` CMake option defaulting to 23; prove `cpp` + `python` Linux jobs green. **Do not** rewrite kernels in the same PR.
- **Done (first slice):** Linux CI (`cpp`, `python`, `benchmarks`) and release Linux agent pin **g++-14**. CMake `SHANNON_CXX_STANDARD` defaults to 23. `setup.py` `_cxx_std_args` reads `SHANNON_CXX_STANDARD`. Kernels untouched.
- **Done (second slice):** `EntropyExpected` + `DispatchResult::{as_expected,from_expected}` + span expected overloads. Public `HandrailAction` / `InputFormat` / `StreamMode` switches fail closed (skip / no-op / exit 1) on corrupt storage — `assume_unreachable` is not used on those arms (`backend_name(99)` stays `"UNKNOWN"`). `enum_code` at pybind `used_backend` and handrail logs. `move_only_function` callbacks on C++23 (`std::function` hatch). `std::print` when `__cpp_lib_print`, else fprintf. Webhook curl uses `--url` plus an `http(s)` scheme allow-list. No kernel rewrite.
- **Priority:** P2
- **Plan:** `docs/CXX_MODERNIZATION.md` Phase B

### - [x] ENH-037: C++26 dialect default + portable SIMD Horner kernel

- **Why:** Phase C (`std::simd` traits) and the C++26 dialect / remaining
  paradigms were intentionally out of ENH-036. g++-14 accepts `-std=c++26`
  but does **not** ship P1928 `<simd>`, `[simd.math]`, contracts, `#embed`,
  or reflection. The portable kernel is Parallelism TS
  `std::experimental::simd` with the same Horner `exp` / atanh `log2` as
  AVX2 — not scalar `std::exp` per lane.
- **Area:** `CMakeLists.txt`, `setup.py`, `src/shannon/simd_generic.hpp`,
  `entropy_std_simd.cpp`, `types.hpp` (`STD_SIMD=6`), `cxx26.hpp`,
  `unified_dispatch.cpp`
- **First slice:** CMake `SHANNON_CXX_STANDARD` default 26 with compiler
  fallback to 23; experimental-simd traits TU; `Backend::STD_SIMD` override
  only (do not change `best_backend`); `SHANNON_ASSUME`; capability tests
  that match dialect / feature-test macros (do not hard-fail when a newer
  GCC grows mdspan or P1928).
- **Done:** Dialect 20/23/26; `SHANNON_USE_STD_SIMD` (OFF → scalar stub);
  Horner on `native_simd<double>`; golden `StdSimdKernels` + `SimdExpGeneric`;
  `cxx26.hpp` reports optional P1928/contracts/embed/reflection/pack indexing;
  `setup.py` falls back to 23 when `-std=c++26` is rejected.
- **Priority:** P2
- **Plan:** `docs/CXX_MODERNIZATION.md` Phase C + dialect 26 + Phase D hatches

---

## Out of scope for this backlog (do not pick here)

- Re-implementing AgentNotch OTEL transport
- Inventing token/cost numbers
- Full iOS/iPad parity
- 10-minute scheduler / cron infrastructure
- Replacing OpenMP reductions with `std::execution` / P2300
- Calling scalar `std::exp` from a `std::simd` kernel (throughput regression)
- Advertising C++26 in README badges until macOS CI compiles `-std=c++26`
  without CMake fallback
- P1928 `<simd>` retarget (needs `__cpp_lib_simd` on CI — GCC 16)

---

## Test baselines (reference for loops)

| Suite | Last green note |
|---|---|
| `cd Pill && swift build && swift test` | 2026-07-26 swarm: PillCore 924 pass (1 skip); ShannonPill 48; multi-platform 4/4 |
| `pytest hub/tests/ -v` | 2026-07-26 ENH-017: 685 passed, 8 skipped (tool_kind migration + classify) |
| `pytest tests/python/ -q` | 2026-07-26 ENH-009: 180 passed, 51 skipped (pythonpath wired; bare pytest works) |
| Session presenters | `SessionContentPresenterTests` + `AgentLiveSurfaceTests` + `SessionUIWiringTests` |

Update this table when a loop changes suite health.
