import XCTest
@testable import PillCore

/// ENH-028: pure jump-to-host-terminal policy matrix (fail-closed).
final class HostTerminalJumpPolicyTests: XCTestCase {

    // MARK: - Fail-closed / no evidence

    func testNoEvidenceIsNone() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(),
            runningBundleIDs: ["com.mitchellh.ghostty"],
            cwdExists: { _ in true },
            pidAlive: { _ in true }
        )
        XCTAssertEqual(action, .none)
        XCTAssertFalse(action.isAvailable)
        XCTAssertFalse(HostTerminalJumpInput().hasJumpEvidence)
        XCTAssertNil(HostTerminalJumpPolicy.menuTitle(for: action))
    }

    func testWhitespaceOnlyEvidenceIsNone() {
        let input = HostTerminalJumpInput(
            hostBundleID: "  ",
            attachPid: 0,
            hostTerminalLabel: "\n",
            cwd: "   "
        )
        XCTAssertFalse(input.hasJumpEvidence)
        let action = HostTerminalJumpPolicy.decide(
            input: input,
            runningBundleIDs: ["com.mitchellh.ghostty"],
            cwdExists: { _ in true },
            pidAlive: { _ in true }
        )
        XCTAssertEqual(action, .none)
    }

    // MARK: - Activate host by bundle

    func testKnownRunningHostBundleActivates() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(hostBundleID: "com.mitchellh.ghostty"),
            runningBundleIDs: ["com.mitchellh.ghostty"],
            cwdExists: { _ in false },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .activateApp(bundleID: "com.mitchellh.ghostty"))
        XCTAssertTrue(action.isAvailable)
        XCTAssertEqual(action.affordanceLabel, "Jump to terminal")
        XCTAssertEqual(HostTerminalJumpPolicy.menuTitle(for: action), "Jump to terminal")
    }

    func testHostBundleMatchIsCaseInsensitive() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(hostBundleID: "com.Googlecode.iTerm2"),
            runningBundleIDs: ["com.googlecode.iterm2"],
            cwdExists: { _ in false },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .activateApp(bundleID: "com.Googlecode.iTerm2"))
    }

    func testHostBundleNotRunningFallsThroughToLivePid() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(
                hostBundleID: "com.mitchellh.ghostty",
                attachPid: 4242,
                cwd: "/Users/test/Projects/Shannon"
            ),
            runningBundleIDs: ["com.apple.Safari"],
            cwdExists: { $0 == "/Users/test/Projects/Shannon" },
            pidAlive: { $0 == 4242 }
        )
        XCTAssertEqual(action, .activatePid(pid: 4242))
    }

    func testHostBundleNotRunningDeadPidFallsThroughToCwd() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(
                hostBundleID: "com.mitchellh.ghostty",
                attachPid: 99,
                cwd: "/Users/test/Projects/Shannon"
            ),
            runningBundleIDs: ["com.apple.Safari"],
            cwdExists: { $0 == "/Users/test/Projects/Shannon" },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .openCwd(path: "/Users/test/Projects/Shannon"))
    }

    func testHostBundleNotRunningDeadPidMissingCwdIsNone() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(
                hostBundleID: "com.mitchellh.ghostty",
                attachPid: 99
            ),
            runningBundleIDs: ["com.apple.Safari"],
            cwdExists: { _ in true },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .none)
    }

    // MARK: - Terminal label → bundle

    func testHostTerminalLabelGhosttyActivatesWhenRunning() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(hostTerminalLabel: "Ghostty"),
            runningBundleIDs: ["com.mitchellh.ghostty"],
            cwdExists: { _ in false },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .activateApp(bundleID: "com.mitchellh.ghostty"))
    }

    func testHostTerminalLabelPrefixedStillResolves() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(hostTerminalLabel: "Ghostty · claude"),
            runningBundleIDs: ["com.mitchellh.ghostty"],
            cwdExists: { _ in false },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .activateApp(bundleID: "com.mitchellh.ghostty"))
    }

    func testUnknownHostTerminalLabelDoesNotInventBundle() {
        let ids = HostTerminalJumpPolicy.bundleIDs(forHostTerminalLabel: "NotATerminal")
        XCTAssertTrue(ids.isEmpty)
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(hostTerminalLabel: "NotATerminal"),
            runningBundleIDs: ["com.mitchellh.ghostty"],
            cwdExists: { _ in false },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .none)
    }

    func testWarpLabelMatchesStableOrDevBundle() {
        let ids = HostTerminalJumpPolicy.bundleIDs(forHostTerminalLabel: "Warp")
        XCTAssertTrue(ids.contains("dev.warp.warp-stable") || ids.contains("dev.warp.warp"))
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(hostTerminalLabel: "Warp"),
            runningBundleIDs: ["dev.warp.warp"],
            cwdExists: { _ in false },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .activateApp(bundleID: "dev.warp.warp"))
    }

    // MARK: - Live pid

    func testLiveAttachPidActivatesWhenNoBundle() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(attachPid: 7777),
            runningBundleIDs: [],
            cwdExists: { _ in false },
            pidAlive: { $0 == 7777 }
        )
        XCTAssertEqual(action, .activatePid(pid: 7777))
        XCTAssertEqual(action.affordanceLabel, "Jump to terminal")
    }

    func testDeadAttachPidWithoutCwdIsNone() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(attachPid: 1),
            runningBundleIDs: [],
            cwdExists: { _ in false },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .none)
    }

    // MARK: - Open cwd

    func testExistingCwdOpensWhenNoHost() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(cwd: "/tmp/real-project"),
            runningBundleIDs: [],
            cwdExists: { $0 == "/tmp/real-project" },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .openCwd(path: "/tmp/real-project"))
        XCTAssertEqual(action.affordanceLabel, "Open project folder")
    }

    func testMissingCwdIsNone() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(cwd: "/no/such/path"),
            runningBundleIDs: [],
            cwdExists: { _ in false },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .none)
    }

    /// Activate host wins over open-cwd when both are available.
    func testActivatePreferredOverOpenCwd() {
        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(
                hostBundleID: "com.googlecode.iterm2",
                cwd: "/Users/test/proj"
            ),
            runningBundleIDs: ["com.googlecode.iterm2"],
            cwdExists: { _ in true },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .activateApp(bundleID: "com.googlecode.iterm2"))
    }

    // MARK: - Session + attach composition

    func testDecideFromAttachAndSession() {
        let session = AgentSession(
            id: "s1",
            agentId: "claude_code",
            displayName: "Claude Code",
            presence: .live,
            status: .active,
            sourceKind: .artifact,
            updatedAt: Date(),
            cwd: "/Users/test/Shannon",
            hostTerminal: "iTerm"
        )
        let action = HostTerminalJumpPolicy.decide(
            attachBundle: "com.mitchellh.ghostty",
            attachPid: 12,
            session: session,
            runningBundleIDs: ["com.mitchellh.ghostty"],
            cwdExists: { _ in true },
            pidAlive: { _ in true }
        )
        // Explicit attach bundle outranks label and pid.
        XCTAssertEqual(action, .activateApp(bundleID: "com.mitchellh.ghostty"))
    }

    func testSessionCwdOnlyWhenAttachGone() {
        let session = AgentSession(
            id: "s2",
            agentId: "codex",
            displayName: "Codex",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: Date(),
            cwd: "/Users/test/App"
        )
        let action = HostTerminalJumpPolicy.decide(
            attachBundle: "com.mitchellh.ghostty",
            session: session,
            runningBundleIDs: [],
            cwdExists: { $0 == "/Users/test/App" },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .openCwd(path: "/Users/test/App"))
    }

    func testInputFromAgentAndSession() {
        let agent = AgentActivitySnapshot(
            id: "claude_code",
            displayName: "Claude Code",
            status: .active,
            lastTask: "edit",
            source: "gate",
            updatedAt: Date(),
            resumable: true,
            historyCount: 1,
            presence: .live,
            attachPid: 55,
            attachBundle: "com.mitchellh.ghostty"
        )
        let session = AgentSession(
            id: "s3",
            agentId: "claude_code",
            displayName: "Claude Code",
            presence: .live,
            status: .active,
            sourceKind: .gate,
            updatedAt: Date(),
            cwd: "/proj"
        )
        let input = HostTerminalJumpInput(agent: agent, session: session)
        XCTAssertTrue(input.hasJumpEvidence)
        XCTAssertEqual(input.hostBundleID, "com.mitchellh.ghostty")
        XCTAssertEqual(input.attachPid, 55)
        XCTAssertEqual(input.cwd, "/proj")
    }

    // MARK: - HostTerminalJump alias

    func testHostTerminalJumpResolveAlias() {
        let action = HostTerminalJump.resolve(
            attachBundle: "com.apple.Terminal",
            attachPid: nil,
            cwd: nil,
            runningBundleIDs: ["com.apple.Terminal"],
            cwdExists: { _ in false },
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .activateApp(bundleID: "com.apple.Terminal"))
        XCTAssertEqual(HostTerminalJump.menuTitle(for: action), "Jump to terminal")
    }

    // MARK: - Help copy

    func testHelpTextForActions() {
        let activate = HostTerminalJumpPolicy.helpText(
            for: .activateApp(bundleID: "com.mitchellh.ghostty")
        )
        XCTAssertTrue(activate.contains("Ghostty") || activate.contains("ghostty"))

        let pid = HostTerminalJumpPolicy.helpText(for: .activatePid(pid: 9))
        XCTAssertTrue(pid.contains("9"))

        let open = HostTerminalJumpPolicy.helpText(for: .openCwd(path: "/Users/x/MyApp"))
        XCTAssertTrue(open.contains("MyApp"))

        let none = HostTerminalJumpPolicy.helpText(for: .none)
        XCTAssertTrue(none.lowercased().contains("unknown"))
    }

    // MARK: - Bundle id reverse map sanity

    func testBundleIDsCoverTerminalProbeTable() {
        let labels = Set(TerminalAgentProbe.terminalBundleNames.values)
        for label in labels {
            let ids = HostTerminalJumpPolicy.bundleIDs(forHostTerminalLabel: label)
            XCTAssertFalse(ids.isEmpty, "label \(label) must reverse-map")
        }
    }

    // MARK: - Integration smoke (executor)

    func testExecutorNoneIsFalse() {
        XCTAssertFalse(HostTerminalJumpExecutor.perform(.none))
        XCTAssertFalse(HostTerminalJumpPerformer.perform(.none))
    }

    /// Policy decides openCwd for a real directory; executor must fail-closed
    /// when the path is gone (no Finder "can't be found" after defer-delete).
    func testExecutorOpenCwdPolicyAndMissingPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-jump-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.path
        defer { try? FileManager.default.removeItem(at: dir) }

        let action = HostTerminalJumpPolicy.decide(
            input: HostTerminalJumpInput(cwd: path),
            runningBundleIDs: [],
            pidAlive: { _ in false }
        )
        XCTAssertEqual(action, .openCwd(path: path))

        // Missing path: never NSWorkspace.open → no Finder spam.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-jump-missing-\(UUID().uuidString)", isDirectory: true)
            .path
        XCTAssertFalse(HostTerminalJumpExecutor.perform(.openCwd(path: missing)))
    }

    func testDefaultDirectoryExistsRejectsFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-jump-file-\(UUID().uuidString)")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(HostTerminalJumpPolicy.defaultDirectoryExists(file.path))
        XCTAssertTrue(HostTerminalJumpPolicy.defaultDirectoryExists(
            FileManager.default.temporaryDirectory.path
        ))
    }
}
