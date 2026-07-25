import XCTest
@testable import Routes

final class QuickRoutesAndFastActionsTests: XCTestCase {

    func testPresentRouteIsOpenableAbsentIsDisabledNotCreated() {
        var created: [String] = []
        let exists: (String) -> Bool = { path in
            // Only pretend skills exist.
            path.hasSuffix(".claude/skills")
        }
        let routes = QuickRouteCatalog.routes(
            for: "claude_code",
            home: "/Users/test",
            fileExists: exists
        )
        XCTAssertFalse(routes.isEmpty)
        let skills = routes.first { $0.label == "Skills" }
        let settings = routes.first { $0.label == "Settings" }
        XCTAssertEqual(skills?.exists, true)
        XCTAssertEqual(skills?.isOpenable, true)
        XCTAssertEqual(settings?.exists, false)
        XCTAssertEqual(settings?.isOpenable, false)
        // fileExists was only queried — nothing should have been created.
        XCTAssertTrue(created.isEmpty)
        // Paths are under home, never auto-made.
        XCTAssertTrue(skills?.path.hasPrefix("/Users/test/") == true)
    }

    func testCodexCatalogHasSessionsPath() {
        let routes = QuickRouteCatalog.routes(
            for: "codex",
            home: "/home/me",
            fileExists: { _ in false }
        )
        XCTAssertTrue(routes.contains { $0.label == "Sessions" })
        XCTAssertTrue(routes.allSatisfy { !$0.exists && !$0.isOpenable })
    }

    /// AC3: panel list must keep missing routes (dimmed/disabled), not drop them.
    func testPanelRoutesKeepsMissingForDisabledRendering() {
        let exists: (String) -> Bool = { path in
            path.hasSuffix(".claude/skills") || path.hasSuffix(".codex/sessions")
        }
        let panel = QuickRouteCatalog.panelRoutes(
            home: "/Users/test",
            agentIds: ["claude_code", "codex"],
            limit: 40,
            fileExists: exists
        )
        XCTAssertFalse(panel.isEmpty)
        let present = panel.filter(\.exists)
        let missing = panel.filter { !$0.exists }
        XCTAssertFalse(present.isEmpty, "at least skills/sessions should exist in fixture map")
        XCTAssertFalse(missing.isEmpty, "missing catalog paths must remain for dimmed UI")
        XCTAssertTrue(missing.allSatisfy { !$0.isOpenable })
        XCTAssertTrue(present.allSatisfy(\.isOpenable))
        // Present first, then missing (stable UI order for the section).
        XCTAssertEqual(
            panel.prefix(while: \.exists).count,
            present.count,
            "present routes must sort before missing so the panel can dim the rest"
        )
        // Critical: must not be the old .filter(\.exists) behavior.
        XCTAssertTrue(
            panel.contains { $0.label == "Settings" && !$0.exists },
            "Settings missing path must still be listed for disabled rendering"
        )
    }

    func testFastActionSuccessAndFailureStatus() {
        let okRunner = FastActionRunner(home: "/tmp") { cmd, home in
            XCTAssertEqual(home, "/tmp")
            XCTAssertFalse(cmd.isEmpty)
            return (0, "done\n", "")
        }
        let ok = okRunner.run(FastAction(name: "echo", command: "echo hi"))
        XCTAssertEqual(ok.status, .succeeded)
        XCTAssertEqual(ok.exitCode, 0)

        let failRunner = FastActionRunner(home: "/tmp") { _, _ in
            return (2, "", "line1\nbad thing happened\n")
        }
        let fail = failRunner.run(FastAction(name: "boom", command: "false"))
        guard case .failed(let line) = fail.status else {
            return XCTFail("expected failed, got \(fail.status)")
        }
        XCTAssertEqual(line, "bad thing happened")
        XCTAssertEqual(fail.lastFailureLine, "bad thing happened")
    }

    func testFastActionEmptyCommandFails() {
        let runner = FastActionRunner(home: "/tmp") { _, _ in
            XCTFail("should not invoke shell for empty command")
            return (0, "", "")
        }
        let r = runner.run(FastAction(name: "x", command: "   "))
        guard case .failed = r.status else {
            return XCTFail("empty command must fail closed")
        }
    }

    func testFastActionStoreRoundTrip() {
        let actions = [
            FastAction(id: "1", name: "status", command: "git status"),
            FastAction(id: "2", name: "pull", command: "git pull"),
        ]
        let data = FastActionStore.encode(actions)
        let back = FastActionStore.decode(data)
        XCTAssertEqual(back.map(\.name), ["status", "pull"])
        XCTAssertEqual(back.map(\.command), ["git status", "git pull"])
    }

    func testStatusTransitionHelper() {
        let running = FastActionRunStatus.running
        let next = FastActionRunner.transition(
            from: running,
            event: FastActionResult(status: .succeeded, exitCode: 0)
        )
        XCTAssertEqual(next, .succeeded)
    }
}
