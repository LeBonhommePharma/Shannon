import XCTest
@testable import DevServers
@testable import PillCore

final class DevServerTests: XCTestCase {

    func testPortBoundsIgnoreOutsidePolicy() {
        XCTAssertTrue(DevServerPolicy.isInRange(3000))
        XCTAssertTrue(DevServerPolicy.isInRange(5173))
        XCTAssertTrue(DevServerPolicy.isInRange(9999))
        XCTAssertFalse(DevServerPolicy.isInRange(2999))
        XCTAssertFalse(DevServerPolicy.isInRange(10_000))
        XCTAssertFalse(DevServerPolicy.isInRange(22))
        XCTAssertFalse(DevServerPolicy.isInRange(80))
    }

    func testFrameworkAndRuntimeClassification() {
        let next = DevServerPolicy.classify(commandLine: "node node_modules/next/dist/bin/next dev")
        XCTAssertEqual(next.framework, "Next.js")
        XCTAssertEqual(next.runtime, "Node")

        let vite = DevServerPolicy.classify(commandLine: "node ./node_modules/vite/bin/vite.js")
        XCTAssertEqual(vite.framework, "Vite")

        let py = DevServerPolicy.classify(commandLine: "python3 -m http.server 8000")
        XCTAssertEqual(py.framework, "static")
        XCTAssertEqual(py.runtime, "Python")

        let cargo = DevServerPolicy.classify(commandLine: "target/debug/my-api")
        XCTAssertEqual(cargo.runtime, "Rust")
    }

    func testFromListenersFiltersAndLabels() {
        let listeners: [DevServerListener] = [
            .init(port: 22, pid: 1, commandLine: "sshd"), // out of range
            .init(port: 3000, pid: 4242, commandLine: "node next dev", cwd: "/Users/me/webapp"),
            .init(port: 5173, pid: 99, commandLine: "vite", cwd: "/tmp/ui"),
        ]
        let servers = DevServerDiscovery.fromListeners(listeners)
        XCTAssertEqual(servers.map(\.port), [3000, 5173])
        XCTAssertEqual(servers[0].project, "webapp")
        XCTAssertEqual(servers[0].framework, "Next.js")
        XCTAssertEqual(servers[0].url, "http://127.0.0.1:3000")
        XCTAssertTrue(servers[1].detailLine.contains("5173"))
    }

    func testParseLsof() {
        let sample = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        node    12345 me   23u  IPv4 0x1      0t0  TCP *:3000 (LISTEN)
        Python   9999 me   5u  IPv4 0x2      0t0  TCP 127.0.0.1:8080 (LISTEN)
        sshd        1 me   3u  IPv4 0x3      0t0  TCP *:22 (LISTEN)
        """
        let listeners = DevServerDiscovery.parseLsof(sample)
        let ports = Set(listeners.map(\.port))
        XCTAssertTrue(ports.contains(3000))
        XCTAssertTrue(ports.contains(8080))
        XCTAssertFalse(ports.contains(22)) // filtered when building servers, but parse keeps in-range only
        let servers = DevServerDiscovery.fromListeners(listeners)
        XCTAssertEqual(servers.map(\.port).sorted(), [3000, 8080])
    }

    func testStopRefusesProtectedAndInvalid() {
        // Invalid pid — shipped stop() entry point
        let bad = DevServerDiscovery.stop(DevServer(port: 3000, pid: 0))
        if case .failure(let reason) = bad {
            XCTAssertEqual(reason, .invalidPid)
        } else {
            XCTFail("expected invalidPid refusal")
        }

        // Protected name via pure canStop
        let shannon = ProcessKillSafety.canStop(
            pid: 999_001,
            name: "ShannonPill",
            path: "/Apps/ShannonPill.app",
            isAlive: { _ in true }
        )
        if case .failure(let reason) = shannon {
            XCTAssertEqual(reason, .protectedShannon)
        } else {
            XCTFail("expected protectedShannon")
        }

        let system = ProcessKillSafety.canStop(
            pid: 999_002,
            name: "WindowServer",
            path: "/System/Library/PrivateFrameworks/SkyLight.framework/WindowServer",
            isAlive: { _ in true }
        )
        if case .failure(let reason) = system {
            XCTAssertEqual(reason, .protectedSystem)
        } else {
            XCTFail("expected protectedSystem")
        }

        let ok = ProcessKillSafety.canStop(
            pid: 999_003,
            name: "node",
            path: "/usr/local/bin/node",
            isAlive: { _ in true }
        )
        if case .success = ok {
            // ok
        } else {
            XCTFail("node should be stoppable under policy")
        }
    }

    /// Live lsof rows only fill `commandLine` (COMMAND). stop() must feed that
    /// into ProcessKillSafety — not only runtime/framework labels.
    func testStopIdentityUsesLsofCommandLine() {
        let lsofShaped = DevServer(
            port: 3000,
            pid: 4242,
            framework: "Next.js",
            runtime: "Node",
            commandLine: "WindowServer"
        )
        let id = DevServerDiscovery.stopIdentity(for: lsofShaped)
        XCTAssertEqual(id.name, "WindowServer")
        XCTAssertEqual(id.path, "WindowServer")

        // Policy sees the COMMAND even when "name" looks like a harmless runtime.
        let refused = ProcessKillSafety.canStop(
            pid: 999_010,
            name: id.name,
            path: id.path,
            isAlive: { _ in true }
        )
        if case .failure(let reason) = refused {
            XCTAssertEqual(reason, .protectedSystem)
        } else {
            XCTFail("lsof-shaped WindowServer must be refused")
        }

        // commandLine-only (no runtime/framework) — typical bare lsof parse.
        let bare = DevServer(port: 5173, pid: 99, commandLine: "launchd")
        let bareId = DevServerDiscovery.stopIdentity(for: bare)
        XCTAssertEqual(bareId.name, "launchd")
        let bareRefused = ProcessKillSafety.canStop(
            pid: 999_011,
            name: bareId.name,
            path: bareId.path,
            isAlive: { _ in true }
        )
        if case .failure(let reason) = bareRefused {
            XCTAssertEqual(reason, .protectedSystem)
        } else {
            XCTFail("launchd commandLine must be refused")
        }

        // Path-only protected (name empty / wrong) — fragments scan both args.
        let pathOnly = ProcessKillSafety.canStop(
            pid: 999_012,
            name: "Node",
            path: "WindowServer",
            isAlive: { _ in true }
        )
        if case .failure(let reason) = pathOnly {
            XCTAssertEqual(reason, .protectedSystem)
        } else {
            XCTFail("protected COMMAND in path must be refused even if name is Node")
        }
    }

    func testStopOnLsofShapedProtectedDoesNotSignal() {
        // Full stop() entry with invalid-alive would still policy-fail first
        // for pid<=1; for a protected name with dead pid we get notRunning OR
        // protected — either is fail-closed. Use canStop path via identity.
        let server = DevServer(port: 3000, pid: 2, commandLine: "ShannonPill")
        let id = DevServerDiscovery.stopIdentity(for: server)
        let result = ProcessKillSafety.canStop(
            pid: server.pid,
            name: id.name,
            path: id.path,
            isAlive: { _ in true }
        )
        if case .failure(let reason) = result {
            XCTAssertEqual(reason, .protectedShannon)
        } else {
            XCTFail("ShannonPill lsof COMMAND must refuse via stopIdentity")
        }
    }
}
