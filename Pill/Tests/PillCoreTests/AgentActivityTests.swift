import XCTest
@testable import PillCore

final class AgentActivityTests: XCTestCase {

    func testShortenAndJunkFilter() {
        XCTAssertTrue(AgentActivitySnapshot.looksLikeSecretOrJunk(
            "ANTHROPIC_API_KEY=sk-ant-abc123 put this in .env"
        ))
        XCTAssertTrue(AgentActivitySnapshot.looksLikeSecretOrJunk(String(repeating: "x", count: 200)))
        XCTAssertFalse(AgentActivitySnapshot.looksLikeSecretOrJunk("fix CF.com floor on 1SG0"))
        // Gate interaction ids contain "ask-", which the old substring match for
        // "sk-" flagged as a leaked key — blanking every approval prompt and
        // activity label the user actually needed to read.
        XCTAssertFalse(AgentActivitySnapshot.looksLikeSecretOrJunk("approved: ask-hub-ui-1784780299"))
        XCTAssertFalse(AgentActivitySnapshot.looksLikeSecretOrJunk("ask-science-e2e-1784779386"))
        XCTAssertFalse(AgentActivitySnapshot.looksLikeSecretOrJunk("task-42 is risk-free"))
        XCTAssertEqual(
            AgentActivitySnapshot.shorten("approved: ask-hub-ui-1784780299", max: 60),
            "approved: ask-hub-ui-1784780299"
        )
        // Still catches a real bare key.
        XCTAssertTrue(AgentActivitySnapshot.looksLikeSecretOrJunk(
            "use sk-abcdefghij0123456789 now"
        ))
        XCTAssertEqual(
            AgentActivitySnapshot.shorten("hello world this is a long task description", max: 12),
            "hello world…"
        )
    }

    func testCollapsedMultiAgent() {
        // Both connected to the hub and mid-turn — the only case that may be
        // rendered as "2 agents active".
        let a = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude", status: .active,
            lastTask: "wire notch UI", source: "gate",
            updatedAt: Date(), resumable: true, historyCount: 1, presence: .live
        )
        let b = AgentActivitySnapshot(
            id: "codex", displayName: "Codex", status: .active,
            lastTask: "review PR", source: "gate",
            updatedAt: Date().addingTimeInterval(-10), resumable: true,
            historyCount: 0, presence: .live
        )
        let s = AgentActivitySummary(agents: [a, b])
        XCTAssertEqual(s.busyCount, 2)
        XCTAssertTrue(s.collapsedText.contains("Claude"))
        XCTAssertTrue(s.collapsedText.contains("+1"))
    }

    /// A pet file is a ⌘D foreground observation, not telemetry. It must never
    /// come back busy — that is exactly the "3 agents active" lie the pill used
    /// to tell about Ghostty, Claude.app and `com.apple.windowmanager`.
    func testReaderLoadsPets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-act-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let agentDir = pets.appendingPathComponent("claude_code", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let state: [String: Any] = [
            "status": "active",
            "last_task": "refine pill UI",
            "updated_at": Date().timeIntervalSince1970,
            "resumable": true,
            "history_count": 2,
            "memory_size": 10,
            "last_cf_delta": NSNull(),
        ]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: agentDir.appendingPathComponent("state.json"))

        let reg: [[String: Any]] = [[
            "id": "claude_code",
            "display_name": "Claude",
            "source": "chat",
            "last_task": "refine pill UI",
            "updated_at": Date().timeIntervalSince1970,
        ]]
        try JSONSerialization.data(withJSONObject: reg)
            .write(to: root.appendingPathComponent("agents.json"))

        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil
        )
        // Still listed, still labelled, still useful…
        XCTAssertEqual(summary.primary?.id, "claude_code")
        XCTAssertEqual(summary.primary?.displayName, "Claude")
        XCTAssertEqual(summary.primary?.lastTask, "refine pill UI")
        XCTAssertTrue(summary.collapsedText.contains("Claude"))
        XCTAssertTrue(summary.collapsedText.contains("refine"))
        // No attach_pid/bundle → observed only; not busy.
        XCTAssertEqual(summary.busyCount, 0)
        XCTAssertEqual(summary.primary?.presence, .observed)
        XCTAssertEqual(summary.primary?.status, .idle)
    }

    /// ⌘D with a still-running host app is **live** (process-attach), not busy.
    func testProcessAttachRunningAppIsLive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let dir = pets.appendingPathComponent("cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "status": "observed", "last_task": "Working in Cursor",
            "updated_at": Date().timeIntervalSince1970 - 600,
            "resumable": true, "attach_bundle": "com.todesktop.cursor",
            "attach_pid": 0,
        ]).write(to: dir.appendingPathComponent("state.json"))
        try JSONSerialization.data(withJSONObject: [[
            "id": "cursor", "display_name": "Cursor", "source": "ide",
            "bundle": "com.todesktop.cursor",
            "updated_at": Date().timeIntervalSince1970 - 600,
        ]]).write(to: root.appendingPathComponent("agents.json"))

        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            runningBundleIDs: ["com.todesktop.cursor"]
        )
        XCTAssertEqual(summary.primary?.presence, .live)
        XCTAssertEqual(summary.primary?.status, .idle)
        XCTAssertEqual(summary.busyCount, 0)
        XCTAssertEqual(summary.primary?.statusLine, "live")
        // Live attach refreshes the clock (not frozen at ⌘D − 10m).
        XCTAssertLessThan(
            abs(summary.primary!.updatedAt.timeIntervalSinceNow), 2
        )
    }

    /// Pure socket agent (no attach_pid/bundle) must demote when gate is offline —
    /// no ghost-live after hung-up socket.
    func testPureGateOfflineDemotesWithoutAttachEvidence() {
        let previous = [
            AgentActivitySnapshot(
                id: "science", displayName: "Science", status: .active,
                lastTask: "docking", source: "gate",
                updatedAt: Date().addingTimeInterval(-10),
                resumable: true, historyCount: 5,
                presence: .live,
                attachPid: nil,
                attachBundle: nil
            ),
        ]
        let gateOffline = AgentActivitySnapshot(
            id: "science", displayName: "Science", status: .active,
            lastTask: "docking", source: "gate",
            updatedAt: Date().addingTimeInterval(-10),
            resumable: true, historyCount: 5,
            presence: .offline
        )
        let summary = AgentActivityReader.load(
            petsRoot: FileManager.default.temporaryDirectory,
            registryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("none-\(UUID().uuidString).json"),
            gateDB: nil,
            runningBundleIDs: ["com.apple.Terminal"],
            gateRows: [gateOffline],
            skipPetsScan: true,
            previousAgents: previous
        )
        XCTAssertEqual(summary.agents.count, 1)
        XCTAssertEqual(
            summary.agents.first?.presence, .offline,
            "socket-only agent must not stay live after gate offline"
        )
        XCTAssertEqual(summary.agents.first?.status, .idle)
        XCTAssertEqual(summary.busyCount, 0)
    }

    /// Process-attach + still-running host stays live when gate is offline.
    func testProcessAttachStaysLiveWhenGateOfflineOnSkipPetsPath() {
        let previous = [
            AgentActivitySnapshot(
                id: "cursor", displayName: "Cursor", status: .idle,
                lastTask: "edit", source: "ide",
                updatedAt: Date().addingTimeInterval(-5),
                resumable: false, historyCount: 1,
                presence: .live,
                attachPid: 424242,
                attachBundle: "com.todesktop.cursor"
            ),
        ]
        let gateOffline = AgentActivitySnapshot(
            id: "cursor", displayName: "Cursor", status: .active,
            lastTask: "old", source: "gate",
            updatedAt: Date().addingTimeInterval(-30),
            resumable: true, historyCount: 3,
            presence: .offline
        )
        let summary = AgentActivityReader.load(
            petsRoot: FileManager.default.temporaryDirectory,
            registryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("none-\(UUID().uuidString).json"),
            gateDB: nil,
            runningBundleIDs: ["com.todesktop.cursor"],
            gateRows: [gateOffline],
            skipPetsScan: true,
            previousAgents: previous
        )
        // skipPets re-checks attach: dead pid + live host bundle → live, then
        // reconcile keeps process-attach over offline gate.
        XCTAssertEqual(summary.agents.first?.presence, .live)
        XCTAssertEqual(summary.agents.first?.status, .idle, "attach never invents busy")
        XCTAssertEqual(summary.busyCount, 0)
    }

    /// Gate offline + process still live → stay live (socket hung up, app open).
    func testProcessAttachOutranksOfflineGate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-outrank-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let dir = pets.appendingPathComponent("cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "status": "observed", "last_task": "edit",
            "updated_at": Date().timeIntervalSince1970,
            "attach_bundle": "com.todesktop.cursor",
        ]).write(to: dir.appendingPathComponent("state.json"))
        try JSONSerialization.data(withJSONObject: [[
            "id": "cursor", "display_name": "Cursor", "source": "ide",
            "bundle": "com.todesktop.cursor",
            "updated_at": Date().timeIntervalSince1970,
        ]]).write(to: root.appendingPathComponent("agents.json"))

        let gateRow = AgentActivitySnapshot(
            id: "cursor", displayName: "Cursor", status: .active,
            lastTask: "old gate task", source: "gate",
            updatedAt: Date().addingTimeInterval(-30),
            resumable: true, historyCount: 3, presence: .offline
        )
        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            runningBundleIDs: ["com.todesktop.cursor"],
            gateRows: [gateRow]
        )
        XCTAssertEqual(summary.primary?.presence, .live)
        XCTAssertEqual(summary.primary?.status, .idle, "offline gate must not leave busy")
        XCTAssertEqual(summary.busyCount, 0)
    }

    /// The app behind an observed pet has quit → say "offline", not "seen".
    func testObservedPetWithDeadAppIsOffline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-dead-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let dir = pets.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "status": "active", "last_task": "Working in ChatGPT",
            "updated_at": Date().timeIntervalSince1970, "resumable": true,
        ]).write(to: dir.appendingPathComponent("state.json"))
        try JSONSerialization.data(withJSONObject: [[
            "id": "codex", "display_name": "Codex", "source": "chat",
            "bundle": "com.openai.codex", "last_task": "Working in ChatGPT",
            "updated_at": Date().timeIntervalSince1970,
        ]]).write(to: root.appendingPathComponent("agents.json"))

        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            runningBundleIDs: ["com.apple.finder"]      // codex is not running
        )
        XCTAssertEqual(summary.agents.first?.presence, .offline)
        XCTAssertEqual(summary.busyCount, 0)
        XCTAssertTrue(summary.agents.first?.statusLine.hasPrefix("offline") == true)
    }

    /// Bundle ids are case-insensitive identities. `AgentAppMapper.map`
    /// lowercases what it stores in `agents.json`; NSWorkspace returns the real
    /// casing (`com.microsoft.VSCode`). A raw `Set.contains` therefore judged
    /// every mixed-case app "not running" and marked a live agent offline.
    func testRunningAppWithMixedCaseBundleIDIsNotOffline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-case-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let dir = pets.appendingPathComponent("vscode", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "status": "active", "last_task": "Editing GateDBReader.swift",
            "updated_at": Date().timeIntervalSince1970, "resumable": true,
        ]).write(to: dir.appendingPathComponent("state.json"))
        // Exactly what ⌘D writes: `AgentAppMapper.map` lowercases the bundle id
        // it captures, so the registry never holds the real casing.
        try JSONSerialization.data(withJSONObject: [[
            "id": "vscode", "display_name": "VS Code", "source": "ide",
            "bundle": "com.microsoft.vscode",
            "updated_at": Date().timeIntervalSince1970,
        ]]).write(to: root.appendingPathComponent("agents.json"))

        // NSWorkspace preserves case — this app *is* running.
        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            runningBundleIDs: ["com.microsoft.VSCode", "com.apple.finder"]
        )
        XCTAssertEqual(
            summary.agents.first?.presence, .live,
            "a running mixed-case app must be live (process-attach)"
        )

        // The negative case still works: same casing, app genuinely gone.
        let quit = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            runningBundleIDs: ["com.apple.finder"]
        )
        XCTAssertEqual(quit.agents.first?.presence, .offline)
    }

    func testStaleActiveBecomesIdleInUI() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let agentDir = pets.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let state: [String: Any] = [
            "status": "active",
            "last_task": "old work",
            "updated_at": Date().addingTimeInterval(-3 * 3600).timeIntervalSince1970,
            "resumable": true,
            "history_count": 0,
            "memory_size": 0,
            "last_cf_delta": NSNull(),
        ]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: agentDir.appendingPathComponent("state.json"))

        let summary = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            staleAfter: 45 * 60
        )
        XCTAssertEqual(summary.busyCount, 0)
        XCTAssertEqual(summary.agents.first?.status, .idle)
    }

    /// Regression for the headline bug: a ⌘D pet written 10 minutes ago is
    /// *newer* than the gate row, and the old merge let it win — so a
    /// disconnected agent rendered as "active". The gate must win regardless.
    func testFreshPetCannotOverrideDisconnectedGateAgent() {
        let pet = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude Code", status: .active,
            lastTask: "Working in Claude", source: "chat",
            updatedAt: Date().addingTimeInterval(-600),   // 10 min ago — fresher
            resumable: true, historyCount: 0, presence: .observed
        )
        let gate = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude Code", status: .active,
            lastTask: "e2e status", source: "gate",
            updatedAt: Date().addingTimeInterval(-40 * 3600),  // hung up 40 h ago
            resumable: true, historyCount: 4, presence: .offline
        )
        let s = AgentActivityReader.merge(base: [pet], gate: [gate])
        XCTAssertEqual(s.busyCount, 0)
        XCTAssertEqual(s.agents.first?.status, .idle)
        XCTAssertEqual(s.agents.first?.presence, .offline)
        XCTAssertTrue(s.agents.first?.statusLine.contains("last seen") == true)
        XCTAssertEqual(s.collapsedText, "No active agents")
    }

    /// A connected agent that has gone quiet past `staleAfter` stops counting.
    /// With no heartbeat evidence, ageing `last_seen` is all we have, so it is
    /// also reported offline.
    func testGateAgentGoesIdleWhenQuiet() {
        let gate = AgentActivitySnapshot(
            id: "science", displayName: "Science", status: .active,
            lastTask: "docking", source: "gate",
            updatedAt: Date().addingTimeInterval(-3 * 3600),
            resumable: true, historyCount: 2, presence: .live
        )
        let s = AgentActivityReader.merge(base: [], gate: [gate])
        XCTAssertEqual(s.busyCount, 0)
        XCTAssertEqual(s.agents.first?.presence, .offline)
    }

    /// Same row, but the hub says the connection was open a moment ago. Silence
    /// is then just silence: idle, still live, and honest about how long it has
    /// been. Reporting this agent "offline" was the status bug.
    func testQuietButHeartbeatingAgentStaysLive() {
        let gate = AgentActivitySnapshot(
            id: "science", displayName: "Science", status: .active,
            lastTask: "docking", source: "gate",
            updatedAt: Date().addingTimeInterval(-3 * 3600),
            resumable: true, historyCount: 2, presence: .live,
            heartbeatAt: Date().addingTimeInterval(-5)
        )
        let s = AgentActivityReader.merge(base: [], gate: [gate])
        let a = s.agents.first
        XCTAssertEqual(a?.presence, .live)
        XCTAssertEqual(a?.status, .idle, "quiet for 3h is not 'working'")
        // Quiet live shows "live" (attached), not "idle" — idle looked unattached.
        XCTAssertEqual(a?.statusLine, "live")
        XCTAssertEqual(a?.relativeAge, "3h")
        XCTAssertEqual(s.busyCount, 0)
        XCTAssertEqual(s.connected.count, 1)
    }

    /// A live agent that spoke seconds ago is busy; one that has been silent
    /// past `defaultStaleAfter` is not, heartbeat or no heartbeat.
    func testBusyClaimDecaysAtDefaultStaleAfter() {
        func agent(quietFor: TimeInterval) -> AgentActivitySummary {
            AgentActivityReader.merge(base: [], gate: [
                AgentActivitySnapshot(
                    id: "science", displayName: "Science", status: .active,
                    lastTask: "docking", source: "gate",
                    updatedAt: Date().addingTimeInterval(-quietFor),
                    resumable: true, historyCount: 1, presence: .live,
                    heartbeatAt: Date()
                )
            ])
        }
        XCTAssertEqual(agent(quietFor: 10).busyCount, 1)
        XCTAssertEqual(agent(quietFor: AgentActivityReader.defaultStaleAfter + 30).busyCount, 0)
        XCTAssertLessThanOrEqual(
            AgentActivityReader.defaultStaleAfter, 10 * 60,
            "a 'working' claim must not outlive the user's patience"
        )
    }

    /// The row text is a function of the clock, so the same unchanged snapshot
    /// must render differently a minute later. This is what the monitor diffs
    /// to decide whether a re-render is due — if it compared the rows alone,
    /// "last seen 7m" would sit there for ever.
    func testRenderSignatureFollowsTheClock() {
        let now = Date()
        let a = AgentActivitySnapshot(
            id: "terminal", displayName: "Terminal", status: .idle,
            lastTask: "Working in Ghostty", source: "terminal",
            updatedAt: now.addingTimeInterval(-6 * 60), resumable: false,
            historyCount: 0, presence: .observed
        )
        let summary = AgentActivitySummary(agents: [a], scannedAt: now)
        XCTAssertEqual(a.statusLine(at: now), "seen 6m ago")
        XCTAssertEqual(a.statusLine(at: now.addingTimeInterval(60)), "seen 7m ago")
        // Same minute → nothing to redraw.
        XCTAssertEqual(
            summary.renderSignature(at: now),
            summary.renderSignature(at: now.addingTimeInterval(5))
        )
        // Next minute → redraw.
        XCTAssertNotEqual(
            summary.renderSignature(at: now),
            summary.renderSignature(at: now.addingTimeInterval(60))
        )
    }

    /// Sub-minute second ticks must not thrash the publish signature (pill/popover pop).
    func testRenderSignatureBucketsSubMinuteAges() {
        let now = Date()
        let a = AgentActivitySnapshot(
            id: "ask", displayName: "Claude", status: .active,
            lastTask: "docking", source: "gate",
            updatedAt: now.addingTimeInterval(-20), resumable: true,
            historyCount: 0, presence: .observed
        )
        let summary = AgentActivitySummary(agents: [a], scannedAt: now)
        // 20s and 25s both land in the 15s bucket → same signature.
        XCTAssertEqual(
            summary.renderSignature(at: now),
            summary.renderSignature(at: now.addingTimeInterval(5))
        )
        // Crossing into the next 15s bucket forces a redraw.
        XCTAssertNotEqual(
            summary.renderSignature(at: now),
            summary.renderSignature(at: now.addingTimeInterval(16))
        )
        // Display age stays fine-grained when drawn.
        XCTAssertEqual(a.relativeAge(at: now), "20s")
        XCTAssertEqual(a.relativeAge(at: now.addingTimeInterval(5)), "25s")
    }

    func testSignatureAgeBuckets() {
        let now = Date()
        let t = now.addingTimeInterval(-22)
        XCTAssertEqual(AgentActivitySnapshot.signatureAge(since: t, now: now), "15s")
        XCTAssertEqual(AgentActivitySnapshot.signatureAge(since: t, now: now.addingTimeInterval(10)), "30s")
        XCTAssertEqual(AgentActivitySnapshot.signatureAge(since: now.addingTimeInterval(-3), now: now), "now")
        XCTAssertEqual(AgentActivitySnapshot.signatureAge(since: now.addingTimeInterval(-120), now: now), "2m")
    }

    /// Ages come from each agent's own `updatedAt`, never from a shared scan
    /// timestamp — three rows seen minutes apart must not all read alike.
    func testAgesAreIndependentPerAgent() {
        let now = Date()
        func row(_ id: String, ago: TimeInterval) -> AgentActivitySnapshot {
            AgentActivitySnapshot(
                id: id, displayName: id, status: .idle, lastTask: "", source: "gate",
                updatedAt: now.addingTimeInterval(-ago), resumable: false,
                historyCount: 0, presence: .observed
            )
        }
        let rows = [row("science", ago: 30), row("claude_code", ago: 8 * 60),
                    row("terminal", ago: 2 * 3600)]
        XCTAssertEqual(rows.map { $0.relativeAge(at: now) }, ["30s", "8m", "2h"])
    }

    func testStatusLineNeverInventsWork() {
        let observed = AgentActivitySnapshot(
            id: "terminal", displayName: "Terminal", status: .active,
            lastTask: "Working in Ghostty", source: "terminal",
            updatedAt: Date().addingTimeInterval(-780), resumable: true,
            historyCount: 0, presence: .observed
        )
        XCTAssertEqual(observed.statusLine, "seen 13m ago")
        XCTAssertEqual(AgentActivitySummary(agents: [observed]).busyCount, 0)
    }

    func testClipboardRejectsSecrets() {
        let (id, task) = AgentAppMapper.parseClipboard(
            "ANTHROPIC_API_KEY=sk-ant-secret\nmore junk"
        )
        XCTAssertNil(id)
        XCTAssertNil(task)
    }

    func testClipboardAgentLineAllowed() {
        let (id, task) = AgentAppMapper.parseClipboard("agent: science fix CF.com floor")
        XCTAssertEqual(id, "science")
        XCTAssertEqual(task, "fix CF.com floor")
    }

    /// Claude hub enhancement: live gate `agents` rows win when fresher/busy.
    func testMergePrefersLiveGateAgent() {
        let pet = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude", status: .idle,
            lastTask: "old offline task", source: "chat",
            updatedAt: Date().addingTimeInterval(-120), resumable: false, historyCount: 0
        )
        let gate = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude", status: .active,
            lastTask: "docking canary", source: "gate",
            updatedAt: Date(), resumable: true, historyCount: 4
        )
        let s = AgentActivityReader.merge(base: [pet], gate: [gate])
        XCTAssertEqual(s.busyCount, 1)
        XCTAssertEqual(s.primary?.lastTask, "docking canary")
        XCTAssertEqual(s.primary?.status, .active)
        XCTAssertTrue(s.collapsedText.contains("Claude"))
    }

    /// Gate-only poll (skipPetsScan): must not invent pets, but when seeded with
    /// previousAgents it preserves process-attach live while applying gate rows.
    func testSkipPetsScanReusesPreviousAgents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-skip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let cursorDir = pets.appendingPathComponent("cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "status": "observed", "last_task": "edit",
            "updated_at": Date().timeIntervalSince1970,
            "attach_bundle": "com.todesktop.cursor",
        ]).write(to: cursorDir.appendingPathComponent("state.json"))
        try JSONSerialization.data(withJSONObject: [[
            "id": "cursor", "display_name": "Cursor", "source": "ide",
            "bundle": "com.todesktop.cursor",
            "updated_at": Date().timeIntervalSince1970,
        ]]).write(to: root.appendingPathComponent("agents.json"))

        // Full scan first — process-attach live.
        let full = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            runningBundleIDs: ["com.todesktop.cursor"]
        )
        XCTAssertEqual(full.agents.first?.presence, .live)

        // Gate-only path: empty pets scan, seed previous — still live.
        let gateOnly = AgentActivityReader.load(
            petsRoot: pets.appendingPathComponent("does-not-exist"),
            registryURL: root.appendingPathComponent("missing.json"),
            gateDB: nil,
            runningBundleIDs: ["com.todesktop.cursor"],
            skipPetsScan: true,
            previousAgents: full.agents
        )
        XCTAssertEqual(gateOnly.agents.count, 1)
        XCTAssertEqual(gateOnly.agents.first?.id, "cursor")
        XCTAssertEqual(gateOnly.agents.first?.presence, .live)

        // Without previousAgents, skipPetsScan yields empty pets.
        let empty = AgentActivityReader.load(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            skipPetsScan: true,
            previousAgents: nil
        )
        XCTAssertEqual(empty.agents.count, 0)

        // loadFull(skipPetsScan:) wires the flag through.
        let fullSnap = AgentActivityReader.loadFull(
            petsRoot: pets,
            registryURL: root.appendingPathComponent("agents.json"),
            gateDB: nil,
            skipPetsScan: true,
            previousAgents: full.agents
        )
        XCTAssertEqual(fullSnap.summary.agents.first?.presence, .live)
    }

    func testFullScanIntervalIsInRange() {
        // Pets+registry scan cadence: 15–30 s (P1.9).
        XCTAssertGreaterThanOrEqual(AgentActivityMonitor.fullScanInterval, 15)
        XCTAssertLessThanOrEqual(AgentActivityMonitor.fullScanInterval, 30)
        // Off-main bundle roster helper is the shipped entry for hub refresh.
        let bundles = AgentActivityMonitor.enumerateRunningBundleIDs()
        // On macOS test hosts this is non-empty; emptiness would still be valid.
        _ = bundles
        XCTAssertTrue(
            UICadence.agentFullScanInterval > UICadence.agentHubInterval,
            "full pets scan must be coarser than every gate tick"
        )
    }
}
