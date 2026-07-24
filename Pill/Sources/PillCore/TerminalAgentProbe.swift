import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(AppKit)
import AppKit
import CoreGraphics
#endif

/// Identify *which agent CLI is running inside* a terminal emulator.
///
/// ⌘D captures `NSWorkspace.frontmostApplication`, which for a terminal is the
/// container (Ghostty, iTerm, Warp) — never the thing the user actually means.
/// `BrowserPageProbe` already solves the same problem for browsers by enriching
/// the capture with tab title + URL before mapping; this is the terminal twin of
/// that probe, and `AgentAppMapper.map(bundleID:appName:page:terminal:)` consumes
/// it on exactly the same footing.
///
/// Everything here is libproc + sysctl: no `ps`, no subprocess, no AppleScript,
/// so a capture costs a few hundred syscalls (single-digit milliseconds) and is
/// safe to run inline on the main thread. See `TerminalAgentProbeTests` for the
/// pure-function coverage and `testLiveProbeResolvesRunningTerminalAgent` for the
/// against-real-processes check.
public enum TerminalAgentProbe {

    // MARK: - Model

    /// One process in the snapshot. `path` is empty when libproc denies it
    /// (another user's process); matching then falls back to `name`.
    public struct Process: Sendable, Equatable {
        public var pid: Int32
        public var ppid: Int32
        /// Executable basename as the kernel reports it (`pbi_name`, ≤31 chars).
        public var name: String
        /// Full executable path, or "" when unavailable.
        public var path: String
        /// Wall-clock start, seconds since epoch. Newer wins ties.
        public var startedAt: TimeInterval
        /// argv, only populated for generic runtimes (node/python/…).
        public var arguments: [String]

        public init(
            pid: Int32,
            ppid: Int32,
            name: String,
            path: String = "",
            startedAt: TimeInterval = 0,
            arguments: [String] = []
        ) {
            self.pid = pid
            self.ppid = ppid
            self.name = name
            self.path = path
            self.startedAt = startedAt
            self.arguments = arguments
        }

        /// Prefer the real basename from `path`; `pbi_name` truncates at 31
        /// chars and can lag an exec.
        public var executable: String {
            let fromPath = (path as NSString).lastPathComponent
            return fromPath.isEmpty ? name : fromPath
        }
    }

    /// What a capture found inside the terminal. `agentID` is empty when the
    /// terminal is just a shell — the caller then keeps the generic `terminal`
    /// identity but still gets `emulatorName` for the label.
    public struct Context: Sendable, Equatable {
        public var agentID: String
        public var displayName: String
        /// Executable basename that produced the match ("claude", "grok", …).
        public var executable: String
        public var pid: Int32
        /// "Ghostty" / "iTerm" / "Warp" — never thrown away, even on no match.
        public var emulatorName: String
        /// Every agent found under this terminal, best first. A terminal with
        /// three tabs really can host three different agents.
        public var candidates: [String]

        public init(
            agentID: String = "",
            displayName: String = "",
            executable: String = "",
            pid: Int32 = 0,
            emulatorName: String = "",
            candidates: [String] = []
        ) {
            self.agentID = agentID
            self.displayName = displayName
            self.executable = executable
            self.pid = pid
            self.emulatorName = emulatorName
            self.candidates = candidates
        }

        /// True when no agent CLI was found (the emulator name may still be set).
        public var isEmpty: Bool { agentID.isEmpty }
    }

    // MARK: - Terminal recognition

    /// Bundle id → emulator label. The label is the whole point: today every
    /// one of these collapses to the catalog's "Terminal".
    public static let terminalBundleNames: [String: String] = [
        "com.apple.terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm",
        "dev.warp.warp-stable": "Warp",
        "dev.warp.warp": "Warp",
        "com.github.wez.wezterm": "WezTerm",
        "com.mitchellh.ghostty": "Ghostty",
        "co.zeit.hyper": "Hyper",
        "net.kovidgoyal.kitty": "Kitty",
        "io.alacritty": "Alacritty",
        "org.alacritty": "Alacritty",
        "org.tabby": "Tabby",
        "com.brave.terminal": "Terminal",
    ]

    public static func isTerminal(bundleID: String?, appName: String? = nil) -> Bool {
        emulatorName(bundleID: bundleID, appName: appName) != nil
    }

    /// Best label for the emulator itself. nil ⇒ not a terminal.
    public static func emulatorName(bundleID: String?, appName: String?) -> String? {
        let bid = (bundleID ?? "").lowercased()
        if let hit = terminalBundleNames[bid] { return hit }

        // System agents borrow the app's name — this machine really does run
        // "Dock Extra (Ghostty.app)" (com.apple.dock.external.extra.arm64), which
        // the name fallback below happily called a terminal and then went
        // process-walking the Dock. Every Apple terminal worth knowing is in the
        // table above, so past this point com.apple.* is infrastructure.
        guard !bid.hasPrefix("com.apple.") else { return nil }

        let name = (appName ?? "").lowercased()
        // Same shape without a bundle id: a helper naming the app it serves.
        guard !name.contains(".app)"), !name.contains("(") else { return nil }
        // Name fallbacks for unsigned builds / shifting bundle ids. Ordered so
        // the longer product names win before the generic "terminal".
        let byName: [(String, String)] = [
            ("ghostty", "Ghostty"),
            ("wezterm", "WezTerm"),
            ("alacritty", "Alacritty"),
            ("iterm", "iTerm"),
            ("kitty", "Kitty"),
            ("tabby", "Tabby"),
            ("hyper", "Hyper"),
            ("warp", "Warp"),
            ("terminal", "Terminal"),
        ]
        for (needle, label) in byName where name.contains(needle) {
            // "iTermAI" is a separate product, not a terminal window.
            if needle == "iterm", name.contains("itermai") { continue }
            return label
        }
        return nil
    }

    // MARK: - CLI classification

    public struct Rule: Sendable {
        public let executables: [String]
        public let agentID: String
        public let displayName: String
    }

    /// Whitelist, most specific first. A whitelist (rather than "anything that
    /// isn't a shell") is deliberate: `cd ~/claude-notes` must not mint an agent.
    ///
    /// Only ids the gate accepts appear here — `hub/agent_identity.py` derives
    /// `VALID_AGENTS` from `IDENTITIES`, so inventing an id here would make the
    /// capture register-and-be-rejected.
    public static let rules: [Rule] = [
        .init(executables: ["claude-science", "claudescience", "claude_science"],
              agentID: "science", displayName: "Claude Science"),
        .init(executables: ["claude", "claude-code", "claudecode", "claude_code"],
              agentID: "claude_code", displayName: "Claude Code"),
        .init(executables: ["codex", "codex-cli", "codex-exec"],
              agentID: "codex", displayName: "Codex"),
        .init(executables: ["grok", "grok-cli", "grok-build", "supergrok"],
              agentID: "grok_build", displayName: "Grok Build"),
        .init(executables: ["cowork", "cowork-cli"],
              agentID: "cowork", displayName: "Cowork"),
        .init(executables: ["dispatch", "claude-dispatch"],
              agentID: "dispatch", displayName: "Dispatch"),
        .init(executables: ["chatgpt"],
              agentID: "chatgpt", displayName: "ChatGPT"),
    ]

    /// Interpreters that tell you nothing on their own — the agent is in argv.
    public static let genericRuntimes: Set<String> = [
        "node", "node-16", "node-18", "node-20", "node-22", "bun", "deno",
        "python", "python3", "python3.10", "python3.11", "python3.12", "python3.13",
        "ruby", "uv", "uvx", "npx", "npm", "pnpm", "yarn", "electron", "sh-wrapper",
    ]

    /// Distinctive install-path fragments, for `node …/cli.js` style launches.
    /// Kept narrow on purpose: a bare "/grok" would match any project folder.
    private static let pathMarkers: [(String, String, String)] = [
        ("claude-science", "science", "Claude Science"),
        ("@anthropic-ai/claude-code", "claude_code", "Claude Code"),
        ("claude-code", "claude_code", "Claude Code"),
        ("/.claude/local/", "claude_code", "Claude Code"),
        ("@openai/codex", "codex", "Codex"),
        ("/.codex/", "codex", "Codex"),
        ("grok-cli", "grok_build", "Grok Build"),
        ("/.grok/", "grok_build", "Grok Build"),
    ]

    /// Terminal plumbing — walked *through*, never reported as an agent.
    public static let shellExecutables: Set<String> = [
        "login", "zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "-fish",
        "dash", "ksh", "tcsh", "csh", "tmux", "tmux-server", "screen", "script",
        "env", "sudo", "ssh", "mosh", "direnv", "starship",
    ]

    /// Strip a trailing version stamp: version managers exec the versioned
    /// binary, so the kernel reports `grok-0.2.111`, not `grok` — measured on
    /// this machine, where a plain basename match found nothing.
    /// Only a pure `-<digits and dots>` tail is removed, so `claude-code` and
    /// `codex-exec` are untouched.
    public static func normalizeExecutable(_ raw: String) -> String {
        var exe = raw.lowercased()
        if exe.hasPrefix("-") { exe.removeFirst() }        // login shells: "-zsh"
        guard let dash = exe.lastIndex(of: "-") else { return exe }
        let tail = exe[exe.index(after: dash)...]
        guard !tail.isEmpty,
              tail.allSatisfy({ $0.isNumber || $0 == "." }),
              tail.contains(where: \.isNumber) else { return exe }
        let head = String(exe[exe.startIndex..<dash])
        return head.isEmpty ? exe : head
    }

    /// Executable basename → agent, or nil. Matches the *basename*, never a
    /// substring of a long path: `/Users/me/claude-notes/bin/build` is not Claude.
    public static func classify(executable: String) -> (agentID: String, displayName: String)? {
        var exe = executable.lowercased()
        if exe.hasPrefix("-") { exe.removeFirst() }
        guard !exe.isEmpty, !shellExecutables.contains(exe) else { return nil }
        let normalized = normalizeExecutable(exe)
        guard !shellExecutables.contains(normalized) else { return nil }
        for rule in rules where rule.executables.contains(exe) || rule.executables.contains(normalized) {
            return (rule.agentID, rule.displayName)
        }
        return nil
    }

    /// `KERN_PROCARGS2` hands back argv immediately followed by the environment,
    /// and the argc it reports is unreliable once a process rewrites its own
    /// argv area (npm does exactly this: argv collapses to the single string
    /// "npm exec endorctl …" and the walk spills into envp).
    ///
    /// That spill is not cosmetic — this user's `PATH` contains
    /// `/Users/…/.grok/bin`, so every `npm exec` under the terminal matched the
    /// `/.grok/` marker and the whole capture resolved to Grok Build. Stop at the
    /// first `KEY=value`, which is where argv provably ended.
    static func agentArguments(_ args: [String]) -> [String] {
        var out: [String] = []
        for arg in args.prefix(16) {
            if isEnvironmentAssignment(arg) { break }
            if arg.hasPrefix("-") { continue }
            if arg.contains(" ") { continue }   // a rewritten process title
            out.append(arg)
        }
        return out
    }

    private static func isEnvironmentAssignment(_ s: String) -> Bool {
        guard let eq = s.firstIndex(of: "="), eq > s.startIndex else { return false }
        return s[s.startIndex..<eq].allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }

    /// Full classification for one process, including the `node …/claude` case.
    public static func classify(process: Process) -> (agentID: String, displayName: String)? {
        if let direct = classify(executable: process.executable) { return direct }

        let exe = normalizeExecutable(process.executable)
        guard genericRuntimes.contains(exe) else { return nil }

        // argv[0] is the interpreter; the agent is in the script arguments.
        let args = agentArguments(process.arguments)
        for arg in args.dropFirst() {
            var base = (arg as NSString).lastPathComponent.lowercased()
            for ext in [".js", ".mjs", ".cjs", ".py", ".ts"] where base.hasSuffix(ext) {
                base = String(base.dropLast(ext.count))
            }
            if let hit = classify(executable: base) { return hit }
        }
        let blob = ([process.path] + args).joined(separator: " ").lowercased()
        for (marker, id, label) in pathMarkers where blob.contains(marker) {
            return (id, label)
        }
        return nil
    }

    // MARK: - Pure resolution (unit-tested without a live machine)

    /// Walk the descendants of `rootPIDs` and pick the agent the user means.
    ///
    /// One emulator process hosts every window and tab, so a terminal genuinely
    /// can have `claude` in two tabs and `grok` in a third. Ordering:
    ///   1. the front window title names one of them (Ghostty/iTerm put the
    ///      foreground command in the title, so this is the real answer when
    ///      it is available at all),
    ///   2. otherwise the most recently started — the tab the user just opened.
    public static func resolve(
        processes: [Process],
        rootPIDs: Set<Int32>,
        windowTitle: String = "",
        emulatorName: String = ""
    ) -> Context {
        let descendants = self.descendants(of: rootPIDs, in: processes)
        var seen = Set<String>()
        var candidates: [(process: Process, agentID: String, label: String, score: Int)] = []

        let title = windowTitle.lowercased()
        let titleTokens = Set(
            title.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
                .map(String.init)
        )

        for proc in descendants {
            guard let hit = classify(process: proc) else { continue }
            let exe = proc.executable.lowercased()
            var score = 0
            if titleTokens.contains(exe) { score = 2 }
            else if !title.isEmpty && title.contains(hit.displayName.lowercased()) { score = 1 }
            candidates.append((proc, hit.agentID, hit.displayName, score))
            seen.insert(hit.agentID)
        }

        guard !candidates.isEmpty else {
            return Context(emulatorName: emulatorName)
        }
        candidates.sort { l, r in
            if l.score != r.score { return l.score > r.score }
            if l.process.startedAt != r.process.startedAt {
                return l.process.startedAt > r.process.startedAt
            }
            return l.process.pid > r.process.pid
        }
        let best = candidates[0]
        // Stable order for the candidate list: best first, then the rest.
        var ordered = [best.agentID]
        for c in candidates.dropFirst() where !ordered.contains(c.agentID) {
            ordered.append(c.agentID)
        }
        return Context(
            agentID: best.agentID,
            displayName: best.label,
            executable: best.process.executable,
            pid: best.process.pid,
            emulatorName: emulatorName,
            candidates: ordered
        )
    }

    /// Breadth-first descendants of `roots`. The agent is normally a *grand*child
    /// (ghostty → login → zsh → claude), so direct children are never enough.
    ///
    /// tmux/screen reparent their server to launchd, which cuts the chain; when a
    /// client is found under the terminal the detached server is adopted as an
    /// extra root so `tmux` sessions still resolve.
    public static func descendants(
        of roots: Set<Int32>,
        in processes: [Process],
        maxDepth: Int = 16,
        maxCount: Int = 2048
    ) -> [Process] {
        guard !roots.isEmpty, !processes.isEmpty else { return [] }
        var childrenOf: [Int32: [Process]] = [:]
        for p in processes where p.ppid != p.pid {
            childrenOf[p.ppid, default: []].append(p)
        }

        func walk(from seeds: Set<Int32>, visited: inout Set<Int32>) -> [Process] {
            var out: [Process] = []
            var frontier = Array(seeds)
            var depth = 0
            while !frontier.isEmpty, depth < maxDepth, out.count < maxCount {
                var next: [Int32] = []
                for pid in frontier {
                    for child in childrenOf[pid] ?? [] where !visited.contains(child.pid) {
                        visited.insert(child.pid)
                        out.append(child)
                        next.append(child.pid)
                    }
                }
                frontier = next
                depth += 1
            }
            return out
        }

        var visited = roots
        var out = walk(from: roots, visited: &visited)

        // Multiplexer servers live under launchd, not under the terminal.
        let usesMultiplexer = out.contains { p in
            let exe = p.executable.lowercased()
            return exe == "tmux" || exe == "screen" || exe.hasPrefix("tmux-")
        }
        if usesMultiplexer {
            let servers = processes.filter { p in
                let exe = p.executable.lowercased()
                return (exe == "tmux" || exe.hasPrefix("tmux-") || exe == "screen")
                    && !visited.contains(p.pid)
            }
            if !servers.isEmpty {
                let seeds = Set(servers.map(\.pid))
                for s in servers where !visited.contains(s.pid) { visited.insert(s.pid) }
                out.append(contentsOf: walk(from: seeds, visited: &visited))
            }
        }
        return out
    }

    // MARK: - Live probe

    /// Live capture for the frontmost terminal. Returns nil when the app is not
    /// a terminal at all; returns a Context with an empty `agentID` when it is a
    /// terminal running nothing agentic.
    public static func probe(bundleID: String?, appName: String?) -> Context? {
        guard let emulator = emulatorName(bundleID: bundleID, appName: appName) else {
            return nil
        }
        #if canImport(AppKit)
        let pids = terminalPIDs(bundleID: bundleID, appName: appName)
        guard !pids.isEmpty else { return Context(emulatorName: emulator) }
        let table = snapshot(resolvingPathsFor: pids)
        let title = frontWindowTitle(pids: pids)
        return resolve(
            processes: table,
            rootPIDs: pids,
            windowTitle: title,
            emulatorName: emulator
        )
        #else
        return Context(emulatorName: emulator)
        #endif
    }

    #if canImport(AppKit)
    private static func terminalPIDs(bundleID: String?, appName: String?) -> Set<Int32> {
        var pids = Set<Int32>()
        if let bid = bundleID, !bid.isEmpty {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
                pids.insert(app.processIdentifier)
            }
        }
        if pids.isEmpty, let name = appName?.lowercased(), !name.isEmpty {
            for app in NSWorkspace.shared.runningApplications
            where (app.localizedName ?? "").lowercased() == name {
                pids.insert(app.processIdentifier)
            }
        }
        if pids.isEmpty, let front = NSWorkspace.shared.frontmostApplication {
            pids.insert(front.processIdentifier)
        }
        return pids
    }

    /// Front (topmost) on-screen window title owned by the terminal. Needs the
    /// Screen Recording entitlement for the *name*; without it this is "" and
    /// resolution simply falls back to recency.
    private static func frontWindowTitle(pids: Set<Int32>) -> String {
        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return ""
        }
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else {
                continue
            }
            guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                return name
            }
        }
        return ""
    }
    #endif

    // MARK: - libproc snapshot

    /// pid/ppid/name for every process, with paths, start times and argv
    /// resolved only for the terminal's own descendants.
    ///
    /// Two passes on purpose: the whole table is one `sysctl`, but `proc_pidpath`
    /// + `KERN_PROCARGS2` per process would not be free.
    ///
    /// The table has to come from `KERN_PROC_ALL`, not from
    /// `proc_listallpids` + `proc_pidinfo`: `/usr/bin/login` is setuid root, so
    /// `proc_pidinfo` refuses it, and login is exactly the link between the
    /// emulator and the shell (ghostty → login → zsh → claude). Losing it
    /// severed every terminal tree on this machine and made the probe find
    /// nothing at all.
    public static func snapshot(resolvingPathsFor roots: Set<Int32>) -> [Process] {
        #if canImport(Darwin)
        var table = processTable()

        // Enrich only what we will actually look at.
        let interesting = Set(descendants(of: roots, in: table).map(\.pid))
        guard !interesting.isEmpty else { return table }

        // Anything living inside the emulator's own .app bundle is its helper,
        // not a user agent (Warp/Hyper are Electron and spawn several).
        let emulatorBundles: Set<String> = Set(roots.compactMap { pid -> String? in
            guard let path = executablePath(pid), let r = path.range(of: ".app/") else {
                return nil
            }
            return String(path[path.startIndex..<r.upperBound])
        })

        for i in table.indices where interesting.contains(table[i].pid) {
            if let info = bsdInfo(table[i].pid) {
                table[i].startedAt = TimeInterval(info.pbi_start_tvsec)
            }
            guard let path = executablePath(table[i].pid) else { continue }
            table[i].path = path
            if emulatorBundles.contains(where: { path.hasPrefix($0) }) {
                // The emulator's own helpers (Warp and Hyper are Electron and
                // spawn several). Children still walk *through* them; the rule
                // whitelist is what keeps them from being reported as agents.
                continue
            }
            let exe = normalizeExecutable((path as NSString).lastPathComponent)
            if genericRuntimes.contains(exe) {
                table[i].arguments = commandLine(table[i].pid)
            }
        }
        return table
        #else
        return []
        #endif
    }

    #if canImport(Darwin)
    /// pid / ppid / comm for every process on the machine, via one
    /// `KERN_PROC_ALL` sysctl — the same source `ps` uses, and the only one that
    /// includes processes we do not own.
    private static func processTable() -> [Process] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Headroom: the table can grow between sizing and reading.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        let capacity = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let count = min(capacity, size / MemoryLayout<kinfo_proc>.stride)
        var out: [Process] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var entry = procs[i]
            let pid = entry.kp_proc.p_pid
            guard pid > 0 else { continue }
            let comm = withUnsafeBytes(of: &entry.kp_proc.p_comm) { cString(from: $0) }
            out.append(Process(
                pid: pid,
                ppid: entry.kp_eproc.e_ppid,
                name: comm
            ))
        }
        return out
    }

    /// Start time, for "which tab did the user just open". Only ever asked for
    /// the terminal's own descendants, which we own, so the setuid-root refusal
    /// that rules `proc_pidinfo` out for the base table does not bite here.
    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard rc == size else { return nil }
        return info
    }

    private static func cString(from raw: UnsafeRawBufferPointer) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count)
        for b in raw {
            if b == 0 { break }
            bytes.append(b)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` is a C `#define` (4 * MAXPATHLEN) and so is
    /// not re-exported into Swift's Darwin module.
    private static let pathInfoMaxSize = 4 * 1024

    private static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: pathInfoMaxSize)
        let rc = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard rc > 0 else { return nil }
        let path = String(cString: buf)
        return path.isEmpty ? nil : path
    }

    /// argv via `KERN_PROCARGS2`. Denied for other users' processes — that is
    /// fine, it only ever refines a generic-runtime guess.
    private static func commandLine(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            dst.copyBytes(from: buf[0..<MemoryLayout<Int32>.size])
        }
        guard argc > 0 else { return [] }

        var out: [String] = []
        var i = MemoryLayout<Int32>.size
        // Layout: argc, exec_path, NUL padding, then argc NUL-separated argv.
        while i < size, buf[i] != 0 { i += 1 }          // skip exec_path
        while i < size, buf[i] == 0 { i += 1 }          // skip padding
        while i < size, out.count < Int(argc) {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            if j > i { out.append(String(decoding: buf[i..<j], as: UTF8.self)) }
            i = j + 1
        }
        return out
    }
    #endif
}
