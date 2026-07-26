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

### - [ ] ENH-019: Publish docking / notifications / timers from Mac hub (or document “not mirrored”)

- **Why:** `MULTI_DEVICE.md` + `ShannonStore.refresh` list `DockingProgress` / `NotificationMirror` / `TimerState`, but `CloudPublisher.publish` only mirrors media / device / one agent / confirmations — consumers may expect empty forever.
- **Area:** `Pill/Sources/ShannonPill/CloudPublishing.swift`, store refresh, docs
- **First slice:** Either wire sources + publish each type with pure tests, **or** document “not mirrored yet” in MULTI_DEVICE.md and stop implying full record matrix.
- **Priority:** P1

### - [ ] ENH-020: Multi-agent `AgentState` roster publish (fail-closed entropy)

- **Why:** `agentSnapshot()` publishes a single ShannonBridge aggregate; multi-agent Mac fleet is not mirrored as `AgentState` rows (confirmations are multi-agent only).
- **Area:** `CloudPublishing.agentSnapshot`, activity roster, `AgentState`
- **First slice:** Publish one `AgentState` per live agent id from activity summary; entropy only when measured; retract exited agents; pure publisher test with InMemory backend.
- **Priority:** P1

### - [ ] ENH-021: Wire or demote `PetCloudRecord`

- **Why:** Serialize-only CloudSyncable-ish pet path exists without `allRecordTypes` / publisher / store consume — dead multi-device surface.
- **Area:** pet cloud types, `ShannonSyncConfig.allRecordTypes`
- **First slice:** Either register + publish/merge with tests, or remove/mark internal and drop false CloudSyncable surface.
- **Priority:** P2

### - [ ] ENH-022: Align publisher entropy path with local `EntropyProvenance.resolve`

- **Why:** Local UI may show gate-measured H while publisher only uses bridge `isMeasured` — devices stay fail-closed (good) but Mac vs phone diverge when demo bridge + real gate coexist.
- **Area:** `CloudPublishing.agentSnapshot`, `EntropyProvenance`
- **First slice:** Document divergence or share one resolve for publish; test demo+gate never publishes collapse as measured.
- **Priority:** P2

---

## Out of scope for this backlog (do not pick here)

- Re-implementing AgentNotch OTEL transport
- Inventing token/cost numbers
- Full iOS/iPad parity
- 10-minute scheduler / cron infrastructure

---

## Test baselines (reference for loops)

| Suite | Last green note |
|---|---|
| `cd Pill && swift build && swift test` | 2026-07-26 swarm: PillCore 924 pass (1 skip); ShannonPill 48; multi-platform 4/4 |
| `pytest hub/tests/ -v` | 2026-07-26 ENH-017: 685 passed, 8 skipped (tool_kind migration + classify) |
| `pytest tests/python/ -q` | 2026-07-26 ENH-009: 180 passed, 51 skipped (pythonpath wired; bare pytest works) |
| Session presenters | `SessionContentPresenterTests` + `AgentLiveSurfaceTests` + `SessionUIWiringTests` |

Update this table when a loop changes suite health.
