import XCTest
@testable import PillCore

final class SessionMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(
        id: String,
        agent: String,
        presence: AgentPresence,
        source: SessionSourceKind,
        status: AgentRunStatus = .idle,
        task: String? = nil,
        tokens: Int? = nil,
        age: TimeInterval = 0
    ) -> AgentSession {
        AgentSession(
            id: id,
            agentId: agent,
            displayName: agent,
            presence: presence,
            status: status,
            sourceKind: source,
            updatedAt: now.addingTimeInterval(-age),
            lastTask: task,
            tokensIn: tokens
        )
    }

    func testGateLiveOutranksObservedAndOffline() {
        let gate = session(id: "gate:claude_code", agent: "claude_code",
                           presence: .live, source: .gate, status: .midTask, task: "from gate")
        let art = session(id: "claude_code:sess1", agent: "claude_code",
                          presence: .observed, source: .artifact, task: "from disk")
        let offline = session(id: "gate:claude_code", agent: "claude_code",
                              presence: .offline, source: .gate, task: "stale")

        let merged = SessionMerge.merge([[art], [gate], [offline]], now: now)
        // Same id gate:claude_code — live wins over offline.
        let gateRow = merged.first { $0.id == "gate:claude_code" }
        XCTAssertEqual(gateRow?.presence, .live)
        XCTAssertEqual(gateRow?.lastTask, "from gate")

        // Activity projection: live gate outranks artifact for same agentId.
        let activity = SessionMerge.projectToActivity(merged + [art])
        let claude = activity.first { $0.id == "claude_code" }
        XCTAssertEqual(claude?.presence, .live)
        XCTAssertTrue(claude?.lastTask.contains("gate") == true || claude?.status == .midTask)
    }

    func testOptionalFieldsStayAbsentWhenMissing() {
        let s = session(id: "a", agent: "codex", presence: .observed, source: .artifact)
        XCTAssertNil(s.tokensIn)
        XCTAssertNil(s.tokensOut)
        XCTAssertNil(s.model)
        XCTAssertNil(s.branch)
        // Negative tokens discarded at init.
        let bad = AgentSession(
            id: "b", agentId: "codex", displayName: "Codex",
            presence: .observed, status: .idle, sourceKind: .artifact,
            updatedAt: now, tokensIn: -5, tokensOut: -1
        )
        XCTAssertNil(bad.tokensIn)
        XCTAssertNil(bad.tokensOut)
    }

    func testRegistryMergesProviders() {
        let reg = SessionRegistry()
        reg.register(GateSessionProvider(agents: [
            AgentActivitySnapshot(
                id: "science", displayName: "Claude Science",
                status: .midTask, lastTask: "docking", source: "gate",
                updatedAt: now, resumable: true, historyCount: 1, presence: .live
            ),
        ]))
        reg.register(StaticSessionProvider(id: "fixture", sessions: [
            session(id: "art:1", agent: "codex", presence: .observed,
                    source: .artifact, task: "artifact only"),
        ]))
        let all = reg.allSessions(now: now)
        XCTAssertEqual(Set(all.map(\.agentId)), Set(["science", "codex"]))
        let science = all.first { $0.agentId == "science" }
        XCTAssertEqual(science?.presence, .live)
        XCTAssertEqual(science?.sourceKind, .gate)
    }

    func testActivitySnapshotProjectionKeepsWorking() {
        let s = session(
            id: "gate:x", agent: "claude_code", presence: .live,
            source: .gate, status: .midTask, task: "Wiring"
        )
        let snap = s.asActivitySnapshot()
        XCTAssertEqual(snap.id, "claude_code")
        XCTAssertEqual(snap.presence, .live)
        XCTAssertEqual(snap.status, .midTask)
        XCTAssertTrue(snap.lastTask.contains("Wiring"))
    }

    /// ENH-003: gate live wins but still absorbs artifact project/branch/model.
    func testPreferFillsMetaFromLoser() {
        let gate = AgentSession(
            id: "gate:claude_code",
            agentId: "claude_code",
            displayName: "Claude Code",
            presence: .live,
            status: .midTask,
            sourceKind: .gate,
            updatedAt: now,
            lastTask: "from gate"
        )
        let art = AgentSession(
            id: "claude_code:sess1",
            agentId: "claude_code",
            displayName: "Claude Code",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: now.addingTimeInterval(-60),
            project: "Shannon",
            lastTask: "from disk",
            model: "Sonnet",
            branch: "feat/hud"
        )
        let preferred = SessionMerge.prefer(gate, art)
        XCTAssertEqual(preferred.presence, .live)
        XCTAssertEqual(preferred.sourceKind, .gate)
        XCTAssertEqual(preferred.lastTask, "from gate")
        XCTAssertEqual(preferred.project, "Shannon")
        XCTAssertEqual(preferred.branch, "feat/hud")
        XCTAssertEqual(preferred.model, "Sonnet")
        // Reverse argument order must yield the same meta fill.
        let preferredRev = SessionMerge.prefer(art, gate)
        XCTAssertEqual(preferredRev.presence, .live)
        XCTAssertEqual(preferredRev.project, "Shannon")
        XCTAssertEqual(preferredRev.branch, "feat/hud")
        XCTAssertEqual(preferredRev.model, "Sonnet")
    }

    /// ENH-003: byAgentId collapses gate + artifact into one roster meta row.
    func testByAgentIdMergesGateAndArtifactMeta() {
        let gate = AgentSession(
            id: "gate:claude_code",
            agentId: "claude_code",
            displayName: "Claude Code",
            presence: .live,
            status: .midTask,
            sourceKind: .gate,
            updatedAt: now,
            lastTask: "Editing Panel"
        )
        let art = AgentSession(
            id: "art:1",
            agentId: "claude_code",
            displayName: "Claude Code",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: now.addingTimeInterval(-120),
            project: "api",
            model: "Opus",
            branch: "main"
        )
        let other = AgentSession(
            id: "art:codex",
            agentId: "codex",
            displayName: "Codex",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: now,
            project: "other"
        )
        let map = SessionMerge.byAgentId([gate, art, other])
        XCTAssertEqual(Set(map.keys), Set(["claude_code", "codex"]))
        let claude = map["claude_code"]
        XCTAssertEqual(claude?.presence, .live)
        XCTAssertEqual(claude?.sourceKind, .gate)
        XCTAssertEqual(claude?.project, "api")
        XCTAssertEqual(claude?.branch, "main")
        XCTAssertEqual(claude?.model, "Opus")
        XCTAssertEqual(claude?.lastTask, "Editing Panel")
        XCTAssertEqual(map["codex"]?.project, "other")
    }
}

/// Test double provider.
struct StaticSessionProvider: SessionProviding {
    let providerId: String
    let id: String
    let sessions: [AgentSession]

    init(id: String, sessions: [AgentSession]) {
        self.providerId = id
        self.id = id
        self.sessions = sessions
    }

    func fetchSessions(now: Date) -> [AgentSession] {
        _ = now
        return sessions
    }
}
