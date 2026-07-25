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
