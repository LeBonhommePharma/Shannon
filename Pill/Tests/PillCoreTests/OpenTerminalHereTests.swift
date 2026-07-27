import XCTest
import AppKit
@testable import Routes
@testable import PillCore

/// ENH-029: pure open-terminal-here policy matrix (fail-closed; no invented cwd).
final class OpenTerminalHereTests: XCTestCase {

    private let terminal = OpenTerminalHerePolicy.defaultTerminalBundleID
    private let ghostty = "com.mitchellh.ghostty"
    private let iterm = "com.googlecode.iterm2"

    // MARK: - Fail-closed / no evidence

    func testNoCwdIsNone() {
        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(),
            cwdExists: { _ in true },
            isTerminalInstalled: { _ in true }
        )
        XCTAssertEqual(action, .none)
        XCTAssertFalse(action.isAvailable)
        XCTAssertFalse(OpenTerminalHereInput().hasWorkspaceEvidence)
        XCTAssertNil(OpenTerminalHerePolicy.menuTitle(for: action))
    }

    func testWhitespaceCwdIsNone() {
        let input = OpenTerminalHereInput(cwd: "   \n")
        XCTAssertFalse(input.hasWorkspaceEvidence)
        let action = OpenTerminalHerePolicy.decide(
            input: input,
            cwdExists: { _ in true },
            isTerminalInstalled: { _ in true }
        )
        XCTAssertEqual(action, .none)
    }

    func testMissingDirectoryCwdIsNone() {
        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(cwd: "/no/such/project"),
            cwdExists: { _ in false },
            isTerminalInstalled: { _ in true }
        )
        XCTAssertEqual(action, .none)
    }

    func testCwdExistsCheckIsRespectedNotInvented() {
        var queried: [String] = []
        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(cwd: "/Users/test/RealProj"),
            cwdExists: { path in
                queried.append(path)
                return path == "/Users/test/RealProj"
            },
            isTerminalInstalled: { $0 == self.terminal }
        )
        XCTAssertEqual(queried, ["/Users/test/RealProj"])
        XCTAssertEqual(action, .launch(cwd: "/Users/test/RealProj", terminalBundleID: terminal))
    }

    // MARK: - Default Terminal.app

    func testExistingCwdLaunchesDefaultTerminal() {
        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(cwd: "/tmp/workspace"),
            cwdExists: { $0 == "/tmp/workspace" },
            isTerminalInstalled: { $0 == self.terminal }
        )
        XCTAssertEqual(action, .launch(cwd: "/tmp/workspace", terminalBundleID: terminal))
        XCTAssertTrue(action.isAvailable)
        XCTAssertEqual(action.affordanceLabel, "Open Terminal here")
        XCTAssertEqual(OpenTerminalHerePolicy.menuTitle(for: action), "Open Terminal here")
    }

    func testDefaultTerminalMissingIsNoneWhenNoPreferred() {
        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(cwd: "/tmp/workspace"),
            cwdExists: { _ in true },
            isTerminalInstalled: { _ in false }
        )
        XCTAssertEqual(action, .none)
    }

    // MARK: - Preferred bundle / label

    func testPreferredInstalledBundleWins() {
        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(
                cwd: "/Users/test/App",
                preferredBundleID: ghostty,
                preferredTerminalLabel: "iTerm"
            ),
            cwdExists: { _ in true },
            isTerminalInstalled: { $0 == self.ghostty || $0 == self.terminal || $0 == self.iterm }
        )
        XCTAssertEqual(action, .launch(cwd: "/Users/test/App", terminalBundleID: ghostty))
    }

    func testPreferredBundleNotInstalledFallsToLabel() {
        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(
                cwd: "/Users/test/App",
                preferredBundleID: ghostty,
                preferredTerminalLabel: "iTerm"
            ),
            cwdExists: { _ in true },
            isTerminalInstalled: { $0 == self.iterm || $0 == self.terminal }
        )
        XCTAssertEqual(action, .launch(cwd: "/Users/test/App", terminalBundleID: iterm))
    }

    func testLabelGhosttyWhenInstalled() {
        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(
                cwd: "/proj",
                preferredTerminalLabel: "Ghostty · claude"
            ),
            cwdExists: { _ in true },
            isTerminalInstalled: { $0 == self.ghostty || $0 == self.terminal }
        )
        XCTAssertEqual(action, .launch(cwd: "/proj", terminalBundleID: ghostty))
    }

    func testUnknownLabelFallsToDefaultTerminal() {
        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(
                cwd: "/proj",
                preferredTerminalLabel: "NotATerminal"
            ),
            cwdExists: { _ in true },
            isTerminalInstalled: { $0 == self.terminal }
        )
        XCTAssertEqual(action, .launch(cwd: "/proj", terminalBundleID: terminal))
    }

    // MARK: - Session composition

    func testDecideFromSessionCwd() {
        let session = AgentSession(
            id: "s1",
            agentId: "claude_code",
            displayName: "Claude Code",
            presence: .live,
            status: .active,
            sourceKind: .artifact,
            updatedAt: Date(),
            cwd: "/Users/test/Shannon",
            hostTerminal: "Ghostty"
        )
        let action = OpenTerminalHerePolicy.decide(
            session: session,
            cwdExists: { $0 == "/Users/test/Shannon" },
            isTerminalInstalled: { $0 == self.ghostty || $0 == self.terminal }
        )
        XCTAssertEqual(action, .launch(cwd: "/Users/test/Shannon", terminalBundleID: ghostty))
    }

    func testSessionWithoutCwdIsNone() {
        let session = AgentSession(
            id: "s2",
            agentId: "codex",
            displayName: "Codex",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: Date()
        )
        let action = OpenTerminalHerePolicy.decide(
            session: session,
            cwdExists: { _ in true },
            isTerminalInstalled: { _ in true }
        )
        XCTAssertEqual(action, .none)
        XCTAssertFalse(OpenTerminalHereInput(session: session).hasWorkspaceEvidence)
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
            attachBundle: ghostty
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
        let input = OpenTerminalHereInput(agent: agent, session: session)
        XCTAssertTrue(input.hasWorkspaceEvidence)
        XCTAssertEqual(input.preferredBundleID, ghostty)
        XCTAssertEqual(input.cwd, "/proj")
    }

    // MARK: - Alias

    func testOpenTerminalHereResolveAlias() {
        let action = OpenTerminalHere.resolve(
            cwd: "/Users/test/App",
            preferredBundleID: nil,
            preferredTerminalLabel: nil,
            cwdExists: { $0 == "/Users/test/App" },
            isTerminalInstalled: { $0 == self.terminal }
        )
        XCTAssertEqual(action, .launch(cwd: "/Users/test/App", terminalBundleID: terminal))
        XCTAssertEqual(OpenTerminalHere.menuTitle(for: action), "Open Terminal here")
    }

    // MARK: - Help copy

    func testHelpTextForActions() {
        let launch = OpenTerminalHerePolicy.helpText(
            for: .launch(cwd: "/Users/x/MyApp", terminalBundleID: ghostty)
        )
        XCTAssertTrue(launch.contains("MyApp"))
        XCTAssertTrue(launch.lowercased().contains("ghostty") || launch.contains("Open"))

        let none = OpenTerminalHerePolicy.helpText(for: .none)
        XCTAssertTrue(none.lowercased().contains("unknown"))
    }

    // MARK: - Integration smoke (executor)

    func testExecutorNoneIsFalse() {
        XCTAssertFalse(OpenTerminalHereExecutor.perform(.none))
        XCTAssertFalse(OpenTerminalHerePerformer.perform(.none))
    }

    func testExecutorLaunchSmoke() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-term-here-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(cwd: dir.path),
            // Live install check for Terminal.app on the test host.
            isTerminalInstalled: { bid in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil
                    || bid.lowercased() == "com.apple.terminal"
            }
        )
        guard case .launch(let path, _) = action else {
            return XCTFail("expected launch for existing temp dir, got \(action)")
        }
        XCTAssertEqual(path, dir.path)
        // Side effect: may open a terminal window — acceptable smoke for ENH-029.
        _ = OpenTerminalHereExecutor.perform(action)
    }

    func testDefaultDirectoryExistsRejectsFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("shannon-term-file-\(UUID().uuidString)")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let action = OpenTerminalHerePolicy.decide(
            input: OpenTerminalHereInput(cwd: file.path),
            cwdExists: HostTerminalJumpPolicy.defaultDirectoryExists,
            isTerminalInstalled: { _ in true }
        )
        XCTAssertEqual(action, .none)
    }
}
