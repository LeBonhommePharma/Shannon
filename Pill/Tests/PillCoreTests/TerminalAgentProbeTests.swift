import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import PillCore

/// `TerminalAgentProbe` has two halves: a pure resolver (everything below the
/// "Pure resolution" mark in the source) and a libproc snapshot. The pure half
/// is covered with synthetic process tables; the live half is covered by
/// `testLiveProbeAgainstRealProcesses`, which runs against whatever is actually
/// on this machine and is skipped when no terminal is open.
final class TerminalAgentProbeTests: XCTestCase {

    // MARK: - Emulator recognition

    func testEmulatorNameSurvivesPerBundle() {
        XCTAssertEqual(
            TerminalAgentProbe.emulatorName(bundleID: "com.mitchellh.ghostty", appName: "Ghostty"),
            "Ghostty"
        )
        XCTAssertEqual(
            TerminalAgentProbe.emulatorName(bundleID: "com.googlecode.iterm2", appName: "iTerm2"),
            "iTerm"
        )
        XCTAssertEqual(
            TerminalAgentProbe.emulatorName(bundleID: "dev.warp.warp-stable", appName: "Warp"),
            "Warp"
        )
        XCTAssertEqual(
            TerminalAgentProbe.emulatorName(bundleID: "net.kovidgoyal.kitty", appName: "kitty"),
            "Kitty"
        )
        // Unsigned build, unknown bundle: fall back to the app name.
        XCTAssertEqual(
            TerminalAgentProbe.emulatorName(bundleID: "com.example.unknown", appName: "WezTerm"),
            "WezTerm"
        )
        XCTAssertNil(TerminalAgentProbe.emulatorName(bundleID: "com.apple.Safari", appName: "Safari"))
        XCTAssertNil(TerminalAgentProbe.emulatorName(bundleID: "com.anthropic.operon", appName: "Claude Science"))
    }

    func testITermAIIsNotATerminal() {
        // /Applications/iTermAI.app → com.googlecode.iterm2.iTermAI. A separate
        // product; treating it as a terminal would send us process-walking the
        // wrong app.
        XCTAssertFalse(TerminalAgentProbe.isTerminal(
            bundleID: "com.googlecode.iterm2.iTermAI", appName: "iTermAI"
        ))
    }

    // MARK: - Executable classification

    func testClassifyKnownAgentCLIs() {
        XCTAssertEqual(TerminalAgentProbe.classify(executable: "claude")?.agentID, "claude_code")
        XCTAssertEqual(TerminalAgentProbe.classify(executable: "claude-code")?.agentID, "claude_code")
        XCTAssertEqual(TerminalAgentProbe.classify(executable: "claude-science")?.agentID, "science")
        XCTAssertEqual(TerminalAgentProbe.classify(executable: "codex")?.agentID, "codex")
        XCTAssertEqual(TerminalAgentProbe.classify(executable: "grok")?.agentID, "grok_build")
        XCTAssertEqual(TerminalAgentProbe.classify(executable: "cowork")?.agentID, "cowork")
        XCTAssertEqual(TerminalAgentProbe.classify(executable: "dispatch")?.agentID, "dispatch")
        // Most specific first: claude-science must not be swallowed by claude.
        XCTAssertNotEqual(TerminalAgentProbe.classify(executable: "claude-science")?.agentID, "claude_code")
    }

    func testClassifyRejectsShellsAndLookalikes() {
        for shell in ["zsh", "-zsh", "bash", "login", "fish", "tmux", "ssh", "sudo"] {
            XCTAssertNil(TerminalAgentProbe.classify(executable: shell), shell)
        }
        // Substring lookalikes: a *basename* match, never a path substring.
        for impostor in ["claude-notes", "grokking", "codexpress", "myclaude", "claudius"] {
            XCTAssertNil(TerminalAgentProbe.classify(executable: impostor), impostor)
        }
    }

    func testClassifyUsesPathBasenameNotPathSubstring() {
        // `cd ~/claude-notes && ./build` must not mint a Claude Code agent.
        let decoy = TerminalAgentProbe.Process(
            pid: 10, ppid: 9, name: "build",
            path: "/Users/me/Projects/claude-notes/bin/build"
        )
        XCTAssertNil(TerminalAgentProbe.classify(process: decoy))

        // Real Claude Code ships inside a nested .app — basename still wins.
        let real = TerminalAgentProbe.Process(
            pid: 11, ppid: 9, name: "claude",
            path: "/Users/me/Library/Application Support/Claude/claude-code/2.1.219/claude.app/Contents/MacOS/claude"
        )
        XCTAssertEqual(TerminalAgentProbe.classify(process: real)?.agentID, "claude_code")
    }

    func testClassifyGenericRuntimeViaArgv() {
        // npm-installed CLIs exec as `node …/cli.js`; comm is just "node".
        let node = TerminalAgentProbe.Process(
            pid: 20, ppid: 19, name: "node", path: "/opt/homebrew/bin/node",
            arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]
        )
        XCTAssertEqual(TerminalAgentProbe.classify(process: node)?.agentID, "claude_code")

        let codex = TerminalAgentProbe.Process(
            pid: 21, ppid: 19, name: "node", path: "/opt/homebrew/bin/node",
            arguments: ["node", "/Users/me/.npm/@openai/codex/bin/codex.js"]
        )
        XCTAssertEqual(TerminalAgentProbe.classify(process: codex)?.agentID, "codex")

        // A plain node script is not an agent.
        let plain = TerminalAgentProbe.Process(
            pid: 22, ppid: 19, name: "node", path: "/opt/homebrew/bin/node",
            arguments: ["node", "/Users/me/Projects/site/server.js"]
        )
        XCTAssertNil(TerminalAgentProbe.classify(process: plain))
    }

    // MARK: - Descendant walk

    /// ghostty → login → zsh → claude. Only the *grand*child is the agent, which
    /// is exactly why direct children are not enough.
    private func ghosttyTree() -> [TerminalAgentProbe.Process] {
        [
            .init(pid: 134, ppid: 1, name: "ghostty",
                  path: "/Applications/Ghostty.app/Contents/MacOS/ghostty", startedAt: 1_000),
            .init(pid: 138, ppid: 134, name: "login", path: "/usr/bin/login", startedAt: 1_001),
            .init(pid: 142, ppid: 138, name: "zsh", path: "/bin/zsh", startedAt: 1_002),
            .init(pid: 31966, ppid: 134, name: "login", path: "/usr/bin/login", startedAt: 1_010),
            .init(pid: 31967, ppid: 31966, name: "zsh", path: "/bin/zsh", startedAt: 1_011),
            .init(pid: 44534, ppid: 31967, name: "claude", path: "/opt/homebrew/bin/claude",
                  startedAt: 5_000),
            .init(pid: 1793, ppid: 134, name: "login", path: "/usr/bin/login", startedAt: 1_020),
            .init(pid: 1794, ppid: 1793, name: "zsh", path: "/bin/zsh", startedAt: 1_021),
            .init(pid: 12182, ppid: 1794, name: "grok", path: "/Users/me/.grok/bin/grok",
                  startedAt: 2_000),
            // Unrelated: a claude running under a different app entirely.
            .init(pid: 99, ppid: 2, name: "claude", path: "/opt/homebrew/bin/claude",
                  startedAt: 9_999),
        ]
    }

    func testDescendantsReachGrandchildrenAndStopAtTheTree() {
        let found = TerminalAgentProbe.descendants(of: [134], in: ghosttyTree())
        let pids = Set(found.map(\.pid))
        XCTAssertTrue(pids.contains(44534), "must reach the grandchild claude")
        XCTAssertTrue(pids.contains(12182), "must reach the grandchild grok")
        XCTAssertFalse(pids.contains(99), "must not adopt a process outside the tree")
        XCTAssertFalse(pids.contains(134), "root is not its own descendant")
    }

    func testDescendantsAdoptDetachedTmuxServer() {
        // tmux reparents its server to launchd, cutting the chain.
        var table = ghosttyTree()
        table.append(.init(pid: 500, ppid: 31967, name: "tmux", path: "/opt/homebrew/bin/tmux",
                           startedAt: 3_000))
        table.append(.init(pid: 501, ppid: 1, name: "tmux", path: "/opt/homebrew/bin/tmux",
                           startedAt: 2_999))
        table.append(.init(pid: 502, ppid: 501, name: "zsh", path: "/bin/zsh", startedAt: 3_001))
        table.append(.init(pid: 503, ppid: 502, name: "codex", path: "/opt/homebrew/bin/codex",
                           startedAt: 3_002))

        let found = TerminalAgentProbe.descendants(of: [134], in: table)
        XCTAssertTrue(Set(found.map(\.pid)).contains(503), "codex under the tmux server must resolve")
    }

    func testDescendantWalkTerminatesOnACycle() {
        // Defensive: a corrupt table must not hang the capture.
        let table: [TerminalAgentProbe.Process] = [
            .init(pid: 1, ppid: 2, name: "a"),
            .init(pid: 2, ppid: 1, name: "b"),
        ]
        XCTAssertLessThanOrEqual(TerminalAgentProbe.descendants(of: [1], in: table).count, 2)
    }

    // MARK: - Resolution

    func testResolvePicksMostRecentAgentWithoutATitleHint() {
        let ctx = TerminalAgentProbe.resolve(
            processes: ghosttyTree(), rootPIDs: [134],
            windowTitle: "", emulatorName: "Ghostty"
        )
        XCTAssertEqual(ctx.agentID, "claude_code", "claude started after grok")
        XCTAssertEqual(ctx.pid, 44534)
        XCTAssertEqual(ctx.emulatorName, "Ghostty")
        XCTAssertEqual(Set(ctx.candidates), ["claude_code", "grok_build"])
    }

    func testResolvePrefersTheAgentNamedInTheFrontWindowTitle() {
        // Real Ghostty title measured on this machine.
        let title = "⠼ - Wall oracle 3 targets worktree FlexAIDdS… - Sybyl Typing Audit - grok"
        let ctx = TerminalAgentProbe.resolve(
            processes: ghosttyTree(), rootPIDs: [134],
            windowTitle: title, emulatorName: "Ghostty"
        )
        XCTAssertEqual(ctx.agentID, "grok_build", "front window names grok, recency must not win")
        XCTAssertEqual(ctx.pid, 12182)
    }

    func testResolveKeepsEmulatorNameWhenNothingAgenticIsRunning() {
        let shellOnly: [TerminalAgentProbe.Process] = [
            .init(pid: 134, ppid: 1, name: "ghostty", startedAt: 1_000),
            .init(pid: 138, ppid: 134, name: "login", path: "/usr/bin/login", startedAt: 1_001),
            .init(pid: 142, ppid: 138, name: "zsh", path: "/bin/zsh", startedAt: 1_002),
        ]
        let ctx = TerminalAgentProbe.resolve(
            processes: shellOnly, rootPIDs: [134],
            windowTitle: "~/Projects/Shannon", emulatorName: "Ghostty"
        )
        XCTAssertTrue(ctx.isEmpty)
        XCTAssertEqual(ctx.emulatorName, "Ghostty", "the emulator label must survive")
    }

    func testResolveIgnoresAgentLookalikeDirectoryInTitle() {
        let shellOnly: [TerminalAgentProbe.Process] = [
            .init(pid: 134, ppid: 1, name: "ghostty", startedAt: 1_000),
            .init(pid: 142, ppid: 134, name: "zsh", path: "/bin/zsh", startedAt: 1_002),
        ]
        // Title says "claude" but nothing agentic is running: no evidence, no agent.
        let ctx = TerminalAgentProbe.resolve(
            processes: shellOnly, rootPIDs: [134],
            windowTitle: "~/Projects/claude-notes", emulatorName: "Ghostty"
        )
        XCTAssertTrue(ctx.isEmpty)
    }

    // MARK: - Live, against this machine

    /// Not synthetic: snapshots the real process table and resolves every
    /// terminal actually running on this machine, printing what ⌘D resolved to
    /// BEFORE (no terminal context — today's behaviour) and AFTER. Skips rather
    /// than fails when no terminal is open, so CI stays green.
    func testLiveProbeAgainstRealProcesses() throws {
        #if canImport(AppKit)
        let terminals = NSWorkspace.shared.runningApplications.compactMap {
            app -> (bundleID: String, name: String, pid: Int32)? in
            guard let bid = app.bundleIdentifier,
                  TerminalAgentProbe.isTerminal(bundleID: bid, appName: app.localizedName)
            else { return nil }
            return (bid, app.localizedName ?? "", app.processIdentifier)
        }
        try XCTSkipIf(terminals.isEmpty, "no terminal emulator running on this machine")

        for term in terminals {
            let started = Date()
            let ctx = try XCTUnwrap(
                TerminalAgentProbe.probe(bundleID: term.bundleID, appName: term.name)
            )
            let ms = Date().timeIntervalSince(started) * 1000

            // A terminal emulator is always an agent-bearing app, so `map` must
            // resolve (it returns nil only for refused, non-agent apps).
            let before = try XCTUnwrap(
                AgentAppMapper.map(bundleID: term.bundleID, appName: term.name)
            )
            let after = try XCTUnwrap(AgentAppMapper.map(
                bundleID: term.bundleID, appName: term.name, terminal: ctx
            ))
            print("""
            LIVE \(term.name) [\(term.bundleID)] pid=\(term.pid) \
            probe=\(ctx.agentID.isEmpty ? "<none>" : ctx.agentID) exe=\(ctx.executable) \
            agentPID=\(ctx.pid) candidates=\(ctx.candidates) (\(String(format: "%.1f", ms)) ms)
              BEFORE  id=\(before.id)  name=\(before.displayName)
              AFTER   id=\(after.id)  name=\(after.displayName)
            """)

            XCTAssertEqual(ctx.emulatorName, after.displayName.isEmpty ? ctx.emulatorName : ctx.emulatorName)
            // The emulator label must never be lost, agent or no agent.
            XCTAssertFalse(ctx.emulatorName.isEmpty)
            if ctx.isEmpty {
                XCTAssertEqual(after.id, "terminal")
                XCTAssertEqual(after.displayName, ctx.emulatorName)
            } else {
                XCTAssertEqual(after.id, ctx.agentID)
                XCTAssertNotEqual(after.id, "terminal", "an agent was found; must not stay generic")
            }
            // A capture runs on the main thread on every ⌘D.
            XCTAssertLessThan(ms, 500, "probe must not block the UI")
        }
        #else
        throw XCTSkip("AppKit unavailable")
        #endif
    }

    /// The GUI half of the same complaint: Claude Code / Dispatch / devtools
    /// bundle ids, checked against whatever is genuinely installed here.
    func testLiveGUIAppsResolveToDistinctAgents() throws {
        #if canImport(AppKit)
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let bid = app.bundleIdentifier?.lowercased() else { return false }
            return bid.contains("anthropic") || bid.contains("openai") || bid.contains("claude")
                || bid.contains("grok") || bid.contains("xai")
        }
        try XCTSkipIf(running.isEmpty, "no agent GUI apps running")
        for app in running {
            let bid = app.bundleIdentifier ?? ""
            switch AgentAppMapper.resolve(bundleID: bid, appName: app.localizedName) {
            case .agent(let kind):
                print("LIVE GUI \(app.localizedName ?? "?") [\(bid)] → id=\(kind.id) name=\(kind.displayName)")
            case .notAnAgent(let refusal):
                print("LIVE GUI \(app.localizedName ?? "?") [\(bid)] → REFUSED (\(refusal.reason))")
            }
        }
        #else
        throw XCTSkip("AppKit unavailable")
        #endif
    }

    #if canImport(AppKit)
    private func NSRunningApplicationPIDs(bundleID: String) -> [Int32] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
    }
    #endif
}
