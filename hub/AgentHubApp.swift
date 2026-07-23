// AgentHubApp.swift — Shannon Hub
// Premium macOS menu-bar command centre for multi-agent AI collaboration.
// Directives A–L + Pet system fully implemented.
//
// Requirements: macOS 13+, Swift 5.9+, Xcode 15+
// Frameworks: SwiftUI, AppKit, AVFoundation, IOKit, SQLite3
// RAM target: <100 MB

import AppKit
import AVFoundation
import Combine
import Foundation
import IOKit
import IOKit.ps
import Network
import Security
import SQLite3
import SwiftUI

// MARK: - Constants

private let kSocketPath  = "/tmp/shannon.sock"
private let kShannonDir  = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".shannon")
private let kDBPath      = kShannonDir.appendingPathComponent("agent_hub.db")
private let kPetsDir     = kShannonDir.appendingPathComponent("pets")
private let kKeychainSvc = "Shannon.AgentHub"
private let kPollInterval: Double = 0.5   // fast DB poll for near-instant status updates
private let kH_threshold:  Double = 3.5   // bits — entropy warning
private let kH_block:      Double = 5.0   // bits — hard block
private let kD_threshold:  Double = 1.8   // bits — disagreement flag

// MARK: - AgentIdentity  (central registry — replaces all switch statements)

enum AuthKind { case local, cloud }

struct AgentIdentity: Identifiable, Equatable {
    let id:        String
    let icon:      String
    let color:     Color
    let shortKey:  String    // single-char @-shortcut
    let shortName: String
    let authKind:  AuthKind

    // Per-agent Apple TTS voice — distinct identifier + pitch per directive E
    var voiceIdentifier: String {
        switch id {
        case "science":     return "com.apple.ttsbundle.Karen-compact"
        case "grok_build":  return "com.apple.ttsbundle.Moira-compact"
        case "claude_code": return "com.apple.ttsbundle.Tom-compact"
        case "cowork":      return "com.apple.ttsbundle.Samantha-compact"
        case "dispatch":    return "com.apple.ttsbundle.Daniel-compact"
        default:            return AVSpeechSynthesisVoiceIdentifierAlex
        }
    }
    var voicePitch: Float {
        switch id {
        case "science":     return 1.15
        case "grok_build":  return 0.85
        case "claude_code": return 0.95
        case "cowork":      return 1.10
        case "dispatch":    return 0.90
        default:            return 1.05   // codex / dataset_runner
        }
    }
    var voiceRate: Float { 0.52 }

    // Directive F — corrected icons
    static let all: [AgentIdentity] = [
        AgentIdentity(id: "claude_code", icon: "🟠",
                      color: Color(red: 1.00, green: 0.50, blue: 0.08),
                      shortKey: "c", shortName: "CC",    authKind: .local),
        AgentIdentity(id: "cowork",      icon: "🟢",
                      color: Color(red: 0.20, green: 0.85, blue: 0.45),
                      shortKey: "w", shortName: "CWork", authKind: .local),
        AgentIdentity(id: "dispatch",    icon: "🟤",
                      color: Color(red: 0.72, green: 0.50, blue: 0.28),
                      shortKey: "d", shortName: "Disp",  authKind: .local),
        AgentIdentity(id: "science",     icon: "🔬",
                      color: Color(red: 1.00, green: 0.72, blue: 0.10),
                      shortKey: "s", shortName: "Sci",   authKind: .local),
        AgentIdentity(id: "grok_build",  icon: "🟣",
                      color: Color(red: 0.68, green: 0.28, blue: 0.98),
                      shortKey: "g", shortName: "Grok",  authKind: .cloud),
        AgentIdentity(id: "codex",       icon: "🔵",
                      color: Color(red: 0.30, green: 0.55, blue: 1.00),
                      shortKey: "x", shortName: "Codex", authKind: .cloud),
        AgentIdentity(id: "chatgpt",     icon: "🟢",
                      color: Color(red: 0.10, green: 0.72, blue: 0.55),
                      shortKey: "p", shortName: "GPT",   authKind: .cloud),
        AgentIdentity(id: "browser",     icon: "🌐",
                      color: Color(red: 0.35, green: 0.55, blue: 0.95),
                      shortKey: "b", shortName: "Web",   authKind: .local),
    ]

    static func find(_ id: String) -> AgentIdentity? { all.first { $0.id == id } }
    static subscript(_ id: String) -> AgentIdentity {
        find(id) ?? AgentIdentity(id: id, icon: "⚙️", color: .gray,
                                   shortKey: "?", shortName: id, authKind: .local)
    }
}

// MARK: - Pet System  (directive: Pet)

struct PetState: Codable, Equatable {
    var status:       String  = "idle"        // "active" | "idle" | "mid_task"
    var lastTask:     String  = ""
    var lastCFDelta:  Double? = nil
    var memorySize:   Int     = 0
    var historyCount: Int     = 0
    var updatedAt:    Date    = .distantPast
    var resumable:    Bool    = false          // true → was mid-task when hub closed
}

final class PetManager: ObservableObject {
    static let shared = PetManager()

    @Published var states: [String: PetState] = [:]
    @Published var memoryAccessingAgents: Set<String> = []

    private var memoryTimers: [String: Timer] = [:]
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private init() { ensureBaseDir(); loadAllStates() }

    // MARK: Directory bootstrap

    func ensureBaseDir() {
        let fm = FileManager.default
        try? fm.createDirectory(at: kPetsDir, withIntermediateDirectories: true)
        for a in AgentIdentity.all { ensurePetDirectory(for: a.id) }
    }

    func ensurePetDirectory(for agentId: String) {
        let fm  = FileManager.default
        let dir = kPetsDir.appendingPathComponent(agentId)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let memory  = dir.appendingPathComponent("memory.md")
        let history = dir.appendingPathComponent("history.jsonl")
        for url in [memory, history] where !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }
        let config = dir.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: config.path) {
            let defaults: [String: Any] = ["voice_enabled": true,
                                            "notify_threshold": kH_threshold]
            if let data = try? JSONSerialization.data(withJSONObject: defaults) {
                fm.createFile(atPath: config.path, contents: data)
            }
        }
        let state = dir.appendingPathComponent("state.json")
        if !fm.fileExists(atPath: state.path) {
            if let data = try? encoder.encode(PetState()) {
                fm.createFile(atPath: state.path, contents: data)
            }
        }
    }

    // MARK: Load / Save

    func loadAllStates() {
        var loaded: [String: PetState] = [:]
        for a in AgentIdentity.all { loaded[a.id] = loadState(for: a.id) }
        DispatchQueue.main.async { self.states = loaded }
    }

    func loadState(for agentId: String) -> PetState {
        let url = kPetsDir.appendingPathComponent(agentId).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url),
              let s = try? decoder.decode(PetState.self, from: data) else { return PetState() }
        return s
    }

    func saveState(_ state: PetState, for agentId: String) {
        let url = kPetsDir.appendingPathComponent(agentId).appendingPathComponent("state.json")
        if let data = try? encoder.encode(state) { try? data.write(to: url, options: .atomic) }
        DispatchQueue.main.async { self.states[agentId] = state }
    }

    // MARK: Memory access animation (2 s auto-clear)

    func signalMemoryAccess(for agentId: String) {
        DispatchQueue.main.async {
            self.memoryAccessingAgents.insert(agentId)
            self.memoryTimers[agentId]?.invalidate()
            self.memoryTimers[agentId] = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { self?.memoryAccessingAgents.remove(agentId) }
            }
        }
    }

    // MARK: Delegation pre-fill helpers

    func readMemorySnippet(for agentId: String, maxBytes: Int = 512) -> String {
        let url = kPetsDir.appendingPathComponent(agentId).appendingPathComponent("memory.md")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        return String(data: data.prefix(maxBytes), encoding: .utf8) ?? ""
    }

    func recentHistory(for agentId: String, lines: Int = 5) -> [String] {
        let url = kPetsDir.appendingPathComponent(agentId).appendingPathComponent("history.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(lines))
    }
}

// MARK: - Keychain Helper  (SecItemAdd / SecItemCopyMatching — never plaintext)

enum KeychainHelper {
    @discardableResult
    static func store(account: String, value: Data) -> Bool {
        _ = delete(account: account)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: kKeychainSvc as CFString,
            kSecAttrAccount: account as CFString,
            kSecValueData:   value,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: kKeychainSvc as CFString,
            kSecAttrAccount: account as CFString,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: kKeychainSvc as CFString,
            kSecAttrAccount: account as CFString,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static func storeToken(_ token: String, for agentId: String) {
        guard let data = token.data(using: .utf8) else { return }
        store(account: "\(agentId).token", value: data)
    }

    static func loadToken(for agentId: String) -> String? {
        guard let data = load(account: "\(agentId).token"),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func hasToken(for agentId: String) -> Bool { loadToken(for: agentId) != nil }
}

// MARK: - Domain Models

enum AgentStatus: String, Codable {
    case idle, active, waiting, blocked, error
    /// Calibrated palette — avoids raw system `.green` / `.red` which look toy-like
    /// against the dark #0D0D0D hub background.
    var color: Color {
        switch self {
        case .idle:    return Color(white: 0.35)
        case .active:  return Color(red: 0.20, green: 0.85, blue: 0.45)   // Shannon green
        case .waiting: return Color(red: 1.00, green: 0.80, blue: 0.20)   // amber
        case .blocked: return Color(red: 1.00, green: 0.50, blue: 0.08)   // orange
        case .error:   return Color(red: 1.00, green: 0.28, blue: 0.22)   // saturated red
        }
    }
}

struct AgentRow {
    var agentId:     String
    var status:      AgentStatus
    var lastSeen:    Date
    var entropy:     Double
    var taskSummary: String
    var authMethod:  String     // "socket_secret" | "keychain" | "none"
}

struct BenchmarkState {
    var agentId:   String
    var progress:  Int          // 0–100
    var stateJSON: String       // raw JSON payload
    var bestCF:    Double?      // decoded from stateJSON["cf"] or ["best_cf"]
    var bestRMSD:  Double?      // decoded from stateJSON["rmsd"] or ["best_rmsd"]
}

struct AgentInteraction: Identifiable {
    enum InteractionKind { case yesNo, choice([String]), info }
    let id       = UUID()
    let agentId:   String
    let prompt:    String
    let kind:      InteractionKind
    var timeoutAt: Date? = nil
    var diff:      String? = nil   // unified diff to show in DiffReviewView
}

struct ToolEvent: Identifiable {
    enum EventKind: String { case bash="Bash", read="Read", write="Write",
                                   edit="Edit", build="Build", dock="Dock", net="Net" }
    let id        = UUID()
    let agentId:  String
    let kind:     EventKind
    let label:    String
    let detail:   String
    let timestamp = Date()
}

struct DelegationRecord: Identifiable {
    let id        = UUID()
    let agentId:  String
    let command:  String
    let outcome:  String
    let at:       Date
}

struct GateEvent {
    var eventType: String
    var agentId:   String
    var payload:   String   // event_label from agent_activity
    var output:    String   // event_output from agent_activity
    var at:        Date
}

// MARK: - Sound Controller  (AVFoundation 8-bit square wave synthesis — local only)

final class SoundController {
    static let shared = SoundController()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    // Per-event toggles
    var enabledEvents: Set<String> = ["task_complete", "approval_needed",
                                       "blocked", "error", "entropy_warn", "connected"]

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func play(event: String) {
        guard enabledEvents.contains(event) else { return }
        let freq: Float
        switch event {
        case "task_complete":   freq = 880
        case "approval_needed": freq = 660
        case "blocked":         freq = 220
        case "error":           freq = 110
        case "entropy_warn":    freq = 440
        case "connected":       freq = 1047
        default:                freq = 440
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let buf = makeSquareWave(freq: freq, duration: 0.12) else { return }
            player.scheduleBuffer(buf, completionHandler: nil)
            if !player.isPlaying { player.play() }
        }
    }

    private func makeSquareWave(freq: Float, duration: Float) -> AVAudioPCMBuffer? {
        let sr = Float(format.sampleRate)
        let fc = AVAudioFrameCount(sr * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: fc) else { return nil }
        buf.frameLength = fc
        let data   = buf.floatChannelData![0]
        let period = sr / freq
        let attack = Int(sr * 0.005)
        let rel    = Int(sr * 0.010)
        for i in 0 ..< Int(fc) {
            let sq: Float = fmodf(Float(i), period) < period / 2 ? 0.25 : -0.25
            var env: Float = 1.0
            if i < attack { env = Float(i) / Float(attack) }
            let tail = Int(fc) - rel
            if i > tail  { env = Float(Int(fc) - i) / Float(rel) }
            data[i] = sq * env
        }
        return buf
    }
}

// MARK: - Voice Controller  (AVSpeechSynthesizer — macOS AVFoundation only, no external API)

final class VoiceController: ObservableObject {
    static let shared = VoiceController()
    private let synth = AVSpeechSynthesizer()

    // Key = "\(agentId).\(event)"
    var enabledCallouts: Set<String> = Set(AgentIdentity.all.flatMap { a in
        ["task_complete", "approval_needed", "resource_alert"].map { "\(a.id).\($0)" }
    })

    private init() {}

    func speak(agentId: String, event: String, text: String) {
        guard enabledCallouts.contains("\(agentId).\(event)") else { return }
        let identity  = AgentIdentity[agentId]
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice           = AVSpeechSynthesisVoice(identifier: identity.voiceIdentifier)
                                 ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.pitchMultiplier = identity.voicePitch
        utterance.rate            = identity.voiceRate
        DispatchQueue.main.async { self.synth.speak(utterance) }
    }

    func taskComplete(agentId: String, summary: String) {
        speak(agentId: agentId, event: "task_complete",
              text: "\(AgentIdentity[agentId].shortName) finished. \(summary)")
    }
    func approvalNeeded(agentId: String, prompt: String) {
        speak(agentId: agentId, event: "approval_needed",
              text: "\(AgentIdentity[agentId].shortName) needs approval. \(prompt)")
    }
    func resourceAlert(_ text: String) {
        speak(agentId: "dispatch", event: "resource_alert", text: text)
    }
}

// MARK: - System Resource Monitor  (IOKit / sysctl / host_processor_info / IOKit power)

struct SystemMetrics {
    var cpuPercent:  Double = 0
    var gpuPercent:  Double = 0
    var ramUsedGB:   Double = 0
    var ramTotalGB:  Double = 0
    var ramPressure: Int    = 0   // 0=ok 1=warn 2=critical
    var ssdUsedGB:   Double = 0
    var ssdTotalGB:  Double = 0
    var thermalState: Int   = 0   // 0=nominal…3=critical
    var batteryPct:  Double = -1  // -1 = desktop / AC-only
    var batteryWatts: Double = 0
    var isCharging:  Bool   = false
}

final class SystemResourceMonitor: ObservableObject {
    @Published var metrics = SystemMetrics()
    private var timer: Timer?

    init() { startPolling() }
    deinit { timer?.invalidate() }

    func startPolling() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var m = SystemMetrics()
            m.cpuPercent   = self.cpuLoad()
            m.gpuPercent   = self.gpuLoad()
            let ram = self.ramInfo(); m.ramUsedGB = ram.0; m.ramTotalGB = ram.1; m.ramPressure = ram.2
            let ssd = self.diskInfo(); m.ssdUsedGB = ssd.0; m.ssdTotalGB = ssd.1
            m.thermalState = self.thermalState()
            let bat = self.batteryInfo(); m.batteryPct = bat.0; m.batteryWatts = bat.1; m.isCharging = bat.2
            DispatchQueue.main.async { self.metrics = m }
        }
    }

    // CPU: delta-based per-core ticks
    private func cpuLoad() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                   &numCPUs, &cpuInfo, &numCPUInfo) == KERN_SUCCESS,
              let info = cpuInfo else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(numCPUInfo)) }
        var usr = 0.0; var sys = 0.0; var idle = 0.0; var nice = 0.0
        let stride = Int(CPU_STATE_MAX)
        for i in 0 ..< Int(numCPUs) {
            let b = i * stride
            usr  += Double(info[b + Int(CPU_STATE_USER)])
            sys  += Double(info[b + Int(CPU_STATE_SYSTEM)])
            idle += Double(info[b + Int(CPU_STATE_IDLE)])
            nice += Double(info[b + Int(CPU_STATE_NICE)])
        }
        let total = usr + sys + idle + nice
        return total > 0 ? ((usr + sys + nice) / total) * 100.0 : 0
    }

    // GPU: IOAccelerator PerformanceStatistics
    private func gpuLoad() -> Double {
        let match = IOServiceMatching("IOAccelerator") as NSMutableDictionary
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == kIOReturnSuccess else { return 0 }
        defer { IOObjectRelease(iter) }
        var maxUtil = 0.0
        var svc = IOIteratorNext(iter)
        while svc != IO_OBJECT_NULL {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any] {
                let u = (perf["Device Utilization %"] as? Double)
                     ?? ((perf["GPU Core Utilization"] as? Double ?? 0) / 10_000_000.0)
                maxUtil = max(maxUtil, u)
            }
            svc = IOIteratorNext(iter)
        }
        return min(maxUtil, 100.0)
    }

    // RAM via vm_statistics64
    private func ramInfo() -> (Double, Double, Int) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                _ = host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let ps = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) +
                    Double(stats.compressor_page_count)) * ps / 1_073_741_824.0
        var size: size_t = 0; var len = size_t(MemoryLayout<size_t>.size)
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        let total = Double(size) / 1_073_741_824.0
        let pressure: Int
        switch ProcessInfo.processInfo.thermalState {
        case .critical: pressure = 2
        case .serious:  pressure = 1
        default:        pressure = 0
        }
        return (used, total, pressure)
    }

    private func diskInfo() -> (Double, Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attrs[.systemSize] as? Int64,
              let free  = attrs[.systemFreeSize] as? Int64 else { return (0, 0) }
        let gb = 1_073_741_824.0
        return (Double(total - free) / gb, Double(total) / gb)
    }

    private func thermalState() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    private func batteryInfo() -> (Double, Double, Bool) {
        guard let info    = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let src     = sources.first,
              let desc    = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any]
        else { return (-1, 0, false) }
        let pct      = desc[kIOPSCurrentCapacityKey as String] as? Double ?? -1
        let charging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
        let current  = desc["Current" as String] as? Double ?? 0
        let voltage  = desc["Voltage" as String] as? Double ?? 0
        return (pct, abs(current * voltage / 1_000_000.0), charging)
    }
}

// MARK: - Diff Model  (directive E — unified diff with syntax highlighting)

struct DiffLine: Identifiable {
    enum Kind { case header, added, removed, context }
    let id:   Int
    let kind: Kind
    let text: String

    var fg: Color {
        switch kind {
        case .header:  return Color(red: 0.4, green: 0.8, blue: 1.0)
        case .added:   return Color(red: 0.4, green: 0.9, blue: 0.4)
        case .removed: return Color(red: 1.0, green: 0.4, blue: 0.4)
        case .context: return Color(white: 0.75)
        }
    }
    var bg: Color {
        switch kind {
        case .added:   return Color(red: 0.0,  green: 0.18, blue: 0.0)
        case .removed: return Color(red: 0.22, green: 0.0,  blue: 0.0)
        default:       return .clear
        }
    }
}

func parseDiff(_ raw: String) -> [DiffLine] {
    raw.components(separatedBy: "\n").enumerated().map { i, line in
        let kind: DiffLine.Kind
        if line.hasPrefix("@@")     { kind = .header  }
        else if line.hasPrefix("+") { kind = .added   }
        else if line.hasPrefix("-") { kind = .removed }
        else                         { kind = .context }
        return DiffLine(id: i, kind: kind, text: line)
    }
}

// MARK: - Flow Layout  (choice chips — directive H)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        for (sv, pt) in zip(subviews, result.origins) {
            sv.place(at: CGPoint(x: pt.x + bounds.minX, y: pt.y + bounds.minY),
                     proposal: .unspecified)
        }
    }
    private func layout(proposal: ProposedViewSize, subviews: Subviews)
        -> (size: CGSize, origins: [CGPoint]) {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        var origins: [CGPoint] = []
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            origins.append(CGPoint(x: x, y: y))
            rowH = max(rowH, sz.height); x += sz.width + spacing
        }
        return (CGSize(width: maxW, height: y + rowH), origins)
    }
}

// MARK: - Gate Socket Client  (Unix socket → shannon_gate.py, persistent, auto-reconnect)

final class GateSocketClient {
    static let shared = GateSocketClient()

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "shannon.gate.client", qos: .utility)
    private var _connected = false
    var isConnected: Bool { _connected }

    private init() { reconnect() }

    func reconnect() {
        connection?.cancel()
        _connected = false
        let ep     = NWEndpoint.unix(path: kSocketPath)
        let params = NWParameters.tcp
        let conn   = NWConnection(to: ep, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?._connected = true
                self?.register()
            case .failed(_), .cancelled:
                self?._connected = false
                self?.queue.asyncAfter(deadline: .now() + 3.0) { self?.reconnect() }
            default:
                break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }

    private func register() {
        sendRaw(["agent_id": "local_test", "task_id": "hub_ui"])
    }

    // Thread-safe JSON send with automatic reconnect on failure
    func sendMessage(_ dict: [String: Any]) {
        queue.async { self.sendRaw(dict) }
    }

    private func sendRaw(_ dict: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(0x0A) // \n delimiter the gate expects
        connection?.send(content: data, completion: .contentProcessed({ [weak self] err in
            if err != nil { self?._connected = false; self?.reconnect() }
        }))
    }

    func sendDelegation(agentId: String?, command: String) {
        sendMessage([
            "agent_id":     "local_test",
            "task_id":      "hub_ui",
            "message_type": "system_event",
            "confidence":   1.0,
            "shannon_H":    0.0,
            "payload": [
                "command":      command,
                "target_agent": agentId ?? "broadcast",
                "source":       "hub_ui",
            ] as [String: Any],
        ])
    }

    func sendApproval(agentId: String, interactionId: String, approved: Bool) {
        sendMessage([
            "agent_id":     "local_test",
            "task_id":      "hub_ui",
            "message_type": "status",
            "confidence":   1.0,
            "shannon_H":    0.0,
            "payload": [
                "target_agent":    agentId,
                "approved":        approved,
                "interaction_id":  interactionId,
                "source":          "hub_ui",
            ] as [String: Any],
        ])
    }
}

// MARK: - AuditDB Reader  (SQLite WAL — polls agent_hub.db every 0.5 s)

final class AuditDBReader: ObservableObject {
    @Published var agents:      [String: AgentRow]       = [:]
    @Published var benchmarks:  [String: BenchmarkState] = [:]
    @Published var events:      [GateEvent]               = []
    @Published var isConnected  = false

    private var db:    OpaquePointer?
    private var timer: Timer?

    init() { openDB(); startPolling() }
    deinit { timer?.invalidate(); sqlite3_close(db) }

    private func openDB() {
        try? FileManager.default.createDirectory(at: kShannonDir, withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(kDBPath.path, &db, flags, nil) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            isConnected = true
        }
    }

    func startPolling() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: kPollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let db else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let a = self.fetchAgents(db); let b = self.fetchBenchmarks(db); let e = self.fetchEvents(db)
            DispatchQueue.main.async { self.agents = a; self.benchmarks = b; self.events = e }
        }
    }

    private func fetchAgents(_ db: OpaquePointer) -> [String: AgentRow] {
        // last_seen_ns is stored as nanoseconds; convert to seconds for Date()
        let sql = """
            SELECT agent_id, status,
                   CAST(last_seen_ns / 1000000000.0 AS REAL) AS last_seen,
                   entropy_score, task_summary, auth_method
            FROM agents;
            """
        var stmt: OpaquePointer?; var result: [String: AgentRow] = [:]
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = str(stmt, 0)
            result[id] = AgentRow(agentId: id,
                status:      AgentStatus(rawValue: str(stmt, 1)) ?? .idle,
                lastSeen:    Date(timeIntervalSince1970: dbl(stmt, 2)),
                entropy:     dbl(stmt, 3),
                taskSummary: str(stmt, 4),
                authMethod:  str(stmt, 5))
        }
        return result
    }

    private func fetchBenchmarks(_ db: OpaquePointer) -> [String: BenchmarkState] {
        // JOIN agents on task_id so the dict is keyed by agent_id (for vm.db.benchmarks[a.id])
        let sql = """
            SELECT COALESCE(a.agent_id, b.task_id), b.completed, b.state_json
            FROM benchmark_state b
            LEFT JOIN agents a ON a.task_id = b.task_id
            ORDER BY b.updated_at DESC;
            """
        var stmt: OpaquePointer?; var result: [String: BenchmarkState] = [:]
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key  = str(stmt, 0)
            let json = str(stmt, 2)
            var cf: Double?; var rmsd: Double?
            if let data = json.data(using: .utf8),
               let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                cf   = obj["cf"]   as? Double ?? obj["best_cf"]   as? Double
                rmsd = obj["rmsd"] as? Double ?? obj["best_rmsd"] as? Double
            }
            result[key] = BenchmarkState(agentId: key,
                progress:  Int(sqlite3_column_int(stmt, 1)),
                stateJSON: json, bestCF: cf, bestRMSD: rmsd)
        }
        return result
    }

    private func fetchEvents(_ db: OpaquePointer) -> [GateEvent] {
        // Fixed columns: event_label (not payload), event_at_ns→seconds (not timestamp)
        let sql = """
            SELECT event_type, agent_id,
                   event_label,
                   CAST(event_at_ns / 1000000000.0 AS REAL) AS at,
                   COALESCE(event_output, '')
            FROM agent_activity
            ORDER BY rowid DESC LIMIT 60;
            """
        var stmt: OpaquePointer?; var result: [GateEvent] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(GateEvent(eventType: str(stmt, 0), agentId: str(stmt, 1),
                                    payload: str(stmt, 2), output: str(stmt, 4),
                                    at: Date(timeIntervalSince1970: dbl(stmt, 3))))
        }
        return result
    }

    // Write a delegation record directly to SQLite so the gate picks it up
    func insertDelegation(agentId: String, taskText: String) {
        guard let db else { return }
        let sql = "INSERT INTO delegations (agent_id, task_text, dispatched_at_ns) VALUES (?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let ns = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        sqlite3_bind_text(stmt, 1, agentId,  -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, taskText, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 3, ns)
        sqlite3_step(stmt)
    }

    private func str(_ s: OpaquePointer?, _ col: Int32) -> String {
        guard let s, let p = sqlite3_column_text(s, col) else { return "" }
        return String(cString: p)
    }
    private func dbl(_ s: OpaquePointer?, _ col: Int32) -> Double {
        guard let s else { return 0 }; return sqlite3_column_double(s, col)
    }
}

// MARK: - Hub View Model

final class HubViewModel: ObservableObject {
    @Published var interactions:   [AgentInteraction]    = []
    @Published var toolEvents:     [ToolEvent]           = []
    @Published var delegations:    [DelegationRecord]    = []
    @Published var selectedAgent:  String?               = nil
    @Published var delegateText:   String                = ""
    @Published var showDelegateBar = false
    @Published var showSettings    = false

    let db       = AuditDBReader()
    let sysmon   = SystemResourceMonitor()
    let pets     = PetManager.shared
    let voice    = VoiceController.shared
    let sound    = SoundController.shared

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Watch events from DB → signal pet memory access + dispatch voice/sound
        db.$events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] events in self?.processGateEvents(events) }
            .store(in: &cancellables)

        // Thermal alerts → voice
        sysmon.$metrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] m in self?.checkResourceAlerts(m) }
            .store(in: &cancellables)
    }

    private func processGateEvents(_ events: [GateEvent]) {
        // Map DB events → ToolEvent objects for the Feed tab
        let kindMap: [String: ToolEvent.EventKind] = [
            "bash": .bash, "dock": .dock, "build": .build,
            "edit": .edit, "read": .read, "write": .write,
            "net": .net, "tool_call": .bash,
        ]
        toolEvents = events.map { evt in
            ToolEvent(agentId: evt.agentId,
                      kind:    kindMap[evt.eventType] ?? .bash,
                      label:   evt.payload,
                      detail:  evt.output)
        }

        // Sound / voice / interaction callouts (dedupe by only looking at fresh events)
        for evt in events.prefix(5) {
            switch evt.eventType {
            case "pet_memory_access":
                pets.signalMemoryAccess(for: evt.agentId)
            case "task_complete":
                sound.play(event: "task_complete")
                voice.taskComplete(agentId: evt.agentId, summary: evt.payload)
            case "approval_needed":
                sound.play(event: "approval_needed")
                voice.approvalNeeded(agentId: evt.agentId, prompt: evt.payload)
                pushInteraction(for: evt)
            case "entropy_warn":
                sound.play(event: "entropy_warn")
            case "blocked":
                sound.play(event: "blocked")
            default: break
            }
        }
    }

    private func checkResourceAlerts(_ m: SystemMetrics) {
        if m.thermalState >= 3 {
            voice.resourceAlert("CPU thermal throttling.")
        } else if m.cpuPercent > 95 {
            voice.resourceAlert("CPU above 95 percent.")
        }
    }

    private func pushInteraction(for evt: GateEvent) {
        let interaction = AgentInteraction(agentId: evt.agentId, prompt: evt.payload, kind: .yesNo,
                                           timeoutAt: Date().addingTimeInterval(30))
        DispatchQueue.main.async { self.interactions.append(interaction) }
    }

    func resolveInteraction(_ id: UUID, approved: Bool) {
        guard let ia = interactions.first(where: { $0.id == id }) else { return }
        // Send approval/denial to the gate over the socket
        GateSocketClient.shared.sendApproval(
            agentId:       ia.agentId,
            interactionId: id.uuidString,
            approved:      approved
        )
        interactions.removeAll { $0.id == id }
    }

    func submitDelegation() {
        let text = delegateText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let target = selectedAgent ?? "broadcast"
        // Persist to SQLite (gate picks this up on next poll / query)
        db.insertDelegation(agentId: target, taskText: text)
        // Also deliver in real-time via the socket
        GateSocketClient.shared.sendDelegation(agentId: selectedAgent, command: text)
        let rec = DelegationRecord(agentId: target, command: text, outcome: "pending", at: Date())
        delegations.insert(rec, at: 0)
        delegateText    = ""
        showDelegateBar = false
    }

    func prefillDelegation(for agentId: String) {
        let snippet  = pets.readMemorySnippet(for: agentId, maxBytes: 200)
        let history  = pets.recentHistory(for: agentId, lines: 3)
        var fill     = "@\(AgentIdentity[agentId].shortKey) "
        if !history.isEmpty { fill += "\n// context: \(history.last ?? "")" }
        if !snippet.isEmpty  { fill += "\n// memory: \(snippet.prefix(80))…" }
        delegateText    = fill
        selectedAgent   = agentId
        showDelegateBar = true
    }
}

// MARK: - AgentDotView  (glow pulse, lock overlay, timeout arc, memory-access animation)

struct AgentDotView: View {
    let identity:     AgentIdentity
    let row:          AgentRow?
    let bench:        BenchmarkState?
    let interaction:  AgentInteraction?
    let isMemAccess:  Bool
    let isPetResumable: Bool

    @State private var glowPhase    = false
    @State private var memPulse     = false
    @State private var timeoutPct   = 0.0

    var body: some View {
        ZStack {
            // Outer glow — 30×30, active agents only
            if row?.status == .active {
                Circle()
                    .fill(identity.color.opacity(glowPhase ? 0.55 : 0.20))
                    .frame(width: 30, height: 30)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                               value: glowPhase)
            }

            // Entropy arc — full arc = healthy (H/12), draining arc = collapsing.
            // Color: identity.color when H ≥ kH_block (healthy ceiling),
            //        orange when approaching kH_block, red at/below kH_threshold.
            if let ent = row?.entropy {
                let frac = max(0, min(ent / 12.0, 1.0))
                let arcColor: Color = ent <= kH_threshold ? .red
                                    : ent < kH_block      ? .orange
                                    :                        identity.color
                Circle()
                    .trim(from: 0, to: frac)
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundColor(arcColor)
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: frac)
            }

            // Core dot — 14×14
            Circle()
                .fill(dotColor)
                .frame(width: 14, height: 14)
                .overlay(
                    // Timeout countdown arc
                    Group {
                        if let ia = interaction, let deadline = ia.timeoutAt {
                            let remaining = max(0, deadline.timeIntervalSinceNow) / 30.0
                            Circle()
                                .trim(from: 0, to: CGFloat(1.0 - remaining))
                                .stroke(Color.yellow, lineWidth: 1.5)
                                .rotationEffect(.degrees(-90))
                        }
                    }
                )

            // Lock badge (cloud agent, no credential)
            if identity.authKind == .cloud && !KeychainHelper.hasToken(for: identity.id) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundColor(.red)
                    .offset(x: 7, y: -7)
            }

            // Memory-access pulsing dot (directive Pet)
            if isMemAccess {
                Circle()
                    .fill(Color.cyan.opacity(memPulse ? 0.9 : 0.3))
                    .frame(width: 4, height: 4)
                    .offset(x: 7, y: 7)
                    .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                               value: memPulse)
            }

            // Mid-task resume indicator
            if isPetResumable {
                Circle()
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 4, height: 4)
                    .offset(x: -7, y: 7)
            }
        }
        .frame(width: 30, height: 30)
        .onAppear { glowPhase = true; memPulse = true }
        .onChange(of: isMemAccess) { _ in memPulse = isMemAccess }
        .help(tooltipText)
    }

    private var dotColor: Color {
        guard let row else { return .gray.opacity(0.4) }
        return row.status.color
    }

    private var tooltipText: String {
        var parts: [String] = [identity.shortName]
        if let r = row {
            parts.append("Status: \(r.status.rawValue)")
            parts.append("Entropy: \(String(format: "%.2f", r.entropy)) bits")
            if !r.taskSummary.isEmpty { parts.append(r.taskSummary) }
        }
        if let b = bench {
            parts.append("Progress: \(b.progress)%")
            if let cf = b.bestCF    { parts.append("CF: \(String(format: "%.1f", cf))") }
            if let rm = b.bestRMSD  { parts.append("RMSD: \(String(format: "%.2f", rm))Å") }
        }
        if identity.authKind == .cloud && !KeychainHelper.hasToken(for: identity.id) {
            parts.append("⚠️ No API key in Keychain")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Diff Review View  (directive E — hover on @@ hunk header expands context)

struct DiffReviewView: View {
    let diff: String
    @State private var expandedHunks: Set<Int> = []

    private var lines: [DiffLine] { parseDiff(diff) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    diffRow(line: line)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 240)
        .background(Color.black.opacity(0.5))
        .cornerRadius(8)
        .font(.system(.caption, design: .monospaced))
    }

    @ViewBuilder
    private func diffRow(line: DiffLine) -> some View {
        let isHunkHeader = line.kind == .header
        let isExpanded   = expandedHunks.contains(line.id)

        VStack(alignment: .leading, spacing: 0) {
            Text(line.text)
                .foregroundColor(line.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(line.bg)
                .background(isHunkHeader && isExpanded ? Color.white.opacity(0.06) : .clear)

            // Expanded context hint
            if isHunkHeader && isExpanded {
                Text("◀ full context expanded")
                    .foregroundColor(.cyan.opacity(0.6))
                    .font(.system(size: 9))
                    .padding(.leading, 8)
            }
        }
        .onHover { hovering in
            if isHunkHeader && hovering {
                withAnimation(.spring(response: 0.25)) { expandedHunks.insert(line.id) }
            } else if isHunkHeader && !hovering {
                withAnimation(.spring(response: 0.25)) { expandedHunks.remove(line.id) }
            }
        }
    }
}

// MARK: - Plan Review View  (⌘Y approve, ⌘N deny, ⌘1-3 choices)

struct PlanReviewView: View {
    let interaction: AgentInteraction
    let onApprove:   () -> Void
    let onDeny:      () -> Void
    let onChoice:    (Int) -> Void

    @State private var timeLeft: Double = 30

    private var timer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text(AgentIdentity[interaction.agentId].icon)
                    .font(.title2)
                Text(AgentIdentity[interaction.agentId].shortName)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(AgentIdentity[interaction.agentId].color)
                Spacer()
                // Timeout arc
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: CGFloat(1.0 - (timeLeft / 30.0)))
                        .stroke(Color.yellow, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 20, height: 20)
                Text("\(Int(timeLeft))s")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.yellow)
            }

            // Prompt
            Text(interaction.prompt)
                .font(.system(.body, design: .default))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            // Diff view (if present)
            if let d = interaction.diff, !d.isEmpty {
                DiffReviewView(diff: d)
            }

            // Action buttons
            HStack(spacing: 8) {
                switch interaction.kind {
                case .yesNo:
                    PlanButton(label: "Approve", key: "⌘Y", accent: .green) { onApprove() }
                    PlanButton(label: "Deny",    key: "⌘N", accent: .red)   { onDeny()    }
                case .choice(let opts):
                    FlowLayout(spacing: 6) {
                        ForEach(Array(opts.enumerated()), id: \.offset) { i, opt in
                            PlanButton(label: "\(i+1). \(opt)", key: "⌘\(i+1)", accent: .blue) {
                                onChoice(i)
                            }
                        }
                    }
                case .info:
                    PlanButton(label: "OK", key: "⌘Y", accent: .gray) { onApprove() }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
        .onReceive(timer) { _ in
            if timeLeft > 0 { timeLeft -= 0.5 }
        }
    }
}

private struct PlanButton: View {
    let label:   String
    let key:     String
    let accent:  Color
    let action:  () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Text(key).foregroundColor(accent.opacity(0.7)).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isHovering ? accent.opacity(0.35) : accent.opacity(0.18))
            .foregroundColor(accent)
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Tool Call Feed View  (Vibe Island style)

struct ToolCallFeedView: View {
    let events: [ToolEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(events.prefix(12)) { evt in
                ToolEventRow(evt: evt)
            }
        }
    }
}

private struct ToolEventRow: View {
    let evt: ToolEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(AgentIdentity[evt.agentId].icon).font(.caption)
                Text(evt.kind.rawValue)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(kindColor)
                Text(evt.label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer()
                Text(timeAgo(evt.timestamp))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }
            if expanded && !evt.detail.isEmpty {
                Text(evt.detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.leading, 22)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.spring(response: 0.2)) { expanded.toggle() } }
    }

    private var kindColor: Color {
        switch evt.kind {
        case .dock:  return Color(red: 0.4, green: 0.9, blue: 1.0)
        case .build: return Color(red: 0.4, green: 1.0, blue: 0.4)
        case .bash:  return Color(red: 1.0, green: 0.85, blue: 0.3)
        case .edit:  return Color(red: 0.9, green: 0.5, blue: 1.0)
        case .read:  return Color(white: 0.65)
        case .write: return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .net:   return Color(red: 0.3, green: 0.7, blue: 1.0)
        }
    }

    private func timeAgo(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60  { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        return "\(s/3600)h"
    }
}

// MARK: - Resource Bar Section  (CPU/GPU/RAM/SSD fill bars + battery)

struct ResourceBarSection: View {
    let m: SystemMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ResourceBar(label: "CPU", value: m.cpuPercent / 100,
                            warn: 0.75, critical: 0.95, color: .cyan)
                ResourceBar(label: "GPU", value: m.gpuPercent / 100,
                            warn: 0.80, critical: 0.95, color: Color(red: 0.7, green: 0.4, blue: 1.0))
            }
            HStack(spacing: 12) {
                ResourceBar(label: "RAM",
                            value: m.ramTotalGB > 0 ? m.ramUsedGB / m.ramTotalGB : 0,
                            warn: 0.75, critical: 0.90,
                            color: Color(red: 0.3, green: 0.85, blue: 0.5),
                            detail: "\(String(format:"%.1f",m.ramUsedGB))/\(String(format:"%.0f",m.ramTotalGB))G")
                ResourceBar(label: "SSD",
                            value: m.ssdTotalGB > 0 ? m.ssdUsedGB / m.ssdTotalGB : 0,
                            warn: 0.85, critical: 0.95,
                            color: Color(red: 1.0, green: 0.72, blue: 0.1),
                            detail: "\(String(format:"%.0f",m.ssdUsedGB))/\(String(format:"%.0f",m.ssdTotalGB))G")
            }
            if m.batteryPct >= 0 {
                BatteryRow(m: m)
            }
            if m.thermalState >= 2 {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.high")
                    Text(thermalLabel(m.thermalState))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(m.thermalState >= 3 ? .red : .orange)
            }
        }
    }
    private func thermalLabel(_ s: Int) -> String {
        switch s { case 3: return "THERMAL CRITICAL"; case 2: return "Thermal Serious"; default: return "" }
    }
}

private struct ResourceBar: View {
    let label:    String
    let value:    Double     // 0…1
    let warn:     Double
    let critical: Double
    let color:    Color
    var detail:   String = ""

    @State private var pulse = false

    private var barColor: Color {
        if value >= critical { return .red }
        if value >= warn     { return .orange }
        return color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text(detail.isEmpty ? "\(Int(value * 100))%" : detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor.opacity(pulse ? 0.55 : 1.0))
                        .frame(width: geo.size.width * min(max(value, 0), 1))
                        .animation(.easeOut(duration: 0.4), value: value)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: value) { v in
            if v >= warn { withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { pulse = true } }
            else { pulse = false }
        }
    }
}

private struct BatteryRow: View {
    let m: SystemMetrics
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: m.isCharging ? "battery.100.bolt" : batteryIcon)
                .foregroundColor(batteryColor)
                .font(.caption)
            Text(m.batteryPct < 0 ? "AC" : "\(Int(m.batteryPct))%")
                .font(.system(size: 10))
                .foregroundColor(batteryColor)
            if m.batteryWatts > 0.1 {
                Text("\(String(format:"%.1f",m.batteryWatts))W")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }
    private var batteryIcon: String {
        let p = m.batteryPct
        if p > 75 { return "battery.100" }
        if p > 50 { return "battery.75" }
        if p > 25 { return "battery.50" }
        if p > 10 { return "battery.25" }
        return "battery.0"
    }
    private var batteryColor: Color {
        if m.isCharging { return .green }
        if m.batteryPct < 15 { return .red }
        if m.batteryPct < 30 { return .orange }
        return .white.opacity(0.7)
    }
}

// MARK: - Delegation Command Bar  (directive K — Space→mode, @ agent picker, pet pre-fill)

struct DelegationBarView: View {
    @ObservedObject var vm: HubViewModel
    @FocusState private var focused: Bool
    @State private var showAgentPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Quick-pick agents
            if showAgentPicker {
                HStack(spacing: 8) {
                    ForEach(AgentIdentity.all) { a in
                        Button {
                            vm.prefillDelegation(for: a.id)
                            showAgentPicker = false
                            focused = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(a.icon).font(.caption)
                                Text("@\(a.shortKey)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(a.color.opacity(0.18))
                            .foregroundColor(a.color)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }

            // Text field
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundColor(.white.opacity(0.35))
                    .font(.caption)
                TextField("@agent command  ·  ⌘A=broadcast", text: $vm.delegateText)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($focused)
                    .onSubmit { vm.submitDelegation() }
                    .onChange(of: vm.delegateText) { text in
                        showAgentPicker = text == "@"
                    }
                Button("Send", action: vm.submitDelegation)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))

            // Recent delegations
            if !vm.delegations.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(vm.delegations.prefix(4)) { rec in
                        HStack(spacing: 6) {
                            Text(AgentIdentity[rec.agentId].icon).font(.caption)
                            Text(rec.command.prefix(48))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                            Spacer()
                            Text(rec.outcome)
                                .font(.system(size: 9))
                                .foregroundColor(rec.outcome == "approved" ? .green : .white.opacity(0.3))
                        }
                    }
                }
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Settings View  (voice per-agent toggles, sound event toggles, Keychain)

struct SettingsView: View {
    @ObservedObject var voice: VoiceController
    @State private var cloudAuth: [String: Bool] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Voice Callouts")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white)
                ForEach(AgentIdentity.all) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(a.icon) \(a.shortName)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(a.color)
                        ForEach(["task_complete", "approval_needed", "resource_alert"], id: \.self) { evt in
                            let key = "\(a.id).\(evt)"
                            Toggle(evt.replacingOccurrences(of: "_", with: " "),
                                   isOn: Binding(
                                    get: { voice.enabledCallouts.contains(key) },
                                    set: { if $0 { voice.enabledCallouts.insert(key) }
                                           else  { voice.enabledCallouts.remove(key) } }
                                   ))
                            .toggleStyle(.switch)
                            .font(.system(size: 10))
                        }
                    }
                    .padding(.leading, 8)
                }

                Divider().opacity(0.3)
                Text("Cloud Credentials (Keychain)")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white)
                ForEach(AgentIdentity.all.filter { $0.authKind == .cloud }) { a in
                    HStack {
                        Text("\(a.icon) \(a.shortName)")
                        Spacer()
                        if KeychainHelper.hasToken(for: a.id) {
                            Text("🔑 Stored").foregroundColor(.green).font(.caption)
                        } else {
                            Text("⚠️ Missing").foregroundColor(.orange).font(.caption)
                        }
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(12)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Main Popover Content View

struct HubPopoverView: View {
    @ObservedObject var vm: HubViewModel
    @State private var selectedTab = 0          // 0=agents 1=feed 2=resources
    @State private var expandedAgentId: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Pill header ──────────────────────────────────────────
            pillHeader

            // ── Inline agent detail (tap a dot to expand) ────────────
            if let aid = expandedAgentId,
               let identity = AgentIdentity.all.first(where: { $0.id == aid }) {
                Divider().opacity(0.15)
                AgentInlineDetail(
                    identity:   identity,
                    row:        vm.db.agents[aid],
                    bench:      vm.db.benchmarks[aid],
                    pet:        vm.pets.states[aid] ?? PetState(),
                    onDelegate: {
                        vm.prefillDelegation(for: aid)
                        expandedAgentId = nil
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().opacity(0.2)

            // ── Tab selector ─────────────────────────────────────────
            tabPicker

            // ── Tab content ──────────────────────────────────────────
            ZStack {
                switch selectedTab {
                case 0: agentsTab
                case 1: feedTab
                case 2: resourcesTab
                default: EmptyView()
                }
            }
            .frame(minHeight: 220)

            // ── Pending interactions ─────────────────────────────────
            if !vm.interactions.isEmpty {
                Divider().opacity(0.2)
                interactionsPanel
            }

            // ── Persistent delegation bar ────────────────────────────
            Divider().opacity(0.2)
            DelegationBarView(vm: vm)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(width: 420)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: expandedAgentId)
    }

    // MARK: Pill header with agent dots

    private var pillHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(AgentIdentity.all) { a in
                    AgentDotView(
                        identity:       a,
                        row:            vm.db.agents[a.id],
                        bench:          vm.db.benchmarks[a.id],
                        interaction:    vm.interactions.first { $0.agentId == a.id },
                        isMemAccess:    vm.pets.memoryAccessingAgents.contains(a.id),
                        isPetResumable: vm.pets.states[a.id]?.resumable ?? false
                    )
                    // Selection ring — appears when this dot is expanded
                    .overlay(
                        Circle()
                            .stroke(a.color, lineWidth: 1.5)
                            .opacity(expandedAgentId == a.id ? 1 : 0)
                            .padding(-3)
                    )
                    .onTapGesture {
                        withAnimation {
                            expandedAgentId = expandedAgentId == a.id ? nil : a.id
                        }
                    }
                }
            }
            Spacer()
            // Worst-case entropy badge — shows min entropy across agents when
            // any agent falls below kH_block (deception risk zone).
            if let minEnt = vm.db.agents.values.map(\.entropy).min(), minEnt < kH_block {
                Text("H=\(String(format:"%.1f",minEnt))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(minEnt <= kH_threshold ? .red : .orange)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background((minEnt <= kH_threshold ? Color.red : .orange).opacity(0.15))
                    .cornerRadius(4)
            }
            Button {
                vm.showSettings = true
            } label: {
                Image(systemName: "gear").font(.caption)
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $vm.showSettings) {
                SettingsView(voice: vm.voice).frame(width: 300, height: 420)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Tab picker (3 tabs — Delegate moved to persistent bar)

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach([("Agents","person.3"), ("Feed","bolt"),
                     ("Resources","cpu")].enumerated().map { $0 }, id: \.offset) { i, tab in
                Button {
                    withAnimation(.spring(response: 0.25)) { selectedTab = i }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.1).font(.system(size: 10))
                        Text(tab.0).font(.system(size: 10, weight: selectedTab == i ? .semibold : .regular))
                    }
                    .padding(.vertical, 6).frame(maxWidth: .infinity)
                    .background(selectedTab == i ? Color.white.opacity(0.08) : .clear)
                    .foregroundColor(selectedTab == i ? .white : .white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Agents tab

    private var agentsTab: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(AgentIdentity.all) { a in
                    AgentRowCard(identity: a, row: vm.db.agents[a.id],
                                 bench: vm.db.benchmarks[a.id],
                                 pet: vm.pets.states[a.id] ?? PetState(),
                                 onDelegate: { vm.prefillDelegation(for: a.id) })
                }
            }
            .padding(10)
        }
    }

    // MARK: Feed tab

    private var feedTab: some View {
        ScrollView {
            ToolCallFeedView(events: vm.toolEvents)
                .padding(10)
        }
    }

    // MARK: Resources tab

    private var resourcesTab: some View {
        ScrollView {
            ResourceBarSection(m: vm.sysmon.metrics)
                .padding(12)
        }
    }

    // MARK: Interactions panel

    private var interactionsPanel: some View {
        VStack(spacing: 6) {
            ForEach(vm.interactions) { ia in
                PlanReviewView(
                    interaction: ia,
                    onApprove: { vm.resolveInteraction(ia.id, approved: true) },
                    onDeny:    { vm.resolveInteraction(ia.id, approved: false) },
                    onChoice:  { _ in vm.resolveInteraction(ia.id, approved: true) }
                )
            }
        }
        .padding(8)
    }
}

// MARK: - Agent Inline Detail  (shown when a dot in pillHeader is tapped)

private struct AgentInlineDetail: View {
    let identity:   AgentIdentity
    let row:        AgentRow?
    let bench:      BenchmarkState?
    let pet:        PetState
    let onDelegate: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Entropy arc + H value
            ZStack {
                let ent = row?.entropy ?? 0
                let frac = max(0, min(ent / 12.0, 1.0))
                let arcColor: Color = ent <= kH_threshold ? .red
                                    : ent < kH_block      ? .orange
                                    :                        identity.color
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 2)
                    .frame(width: 32, height: 32)
                Circle()
                    .trim(from: 0, to: frac)
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundColor(arcColor)
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(-90))
                Text(String(format: "%.1f", ent))
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundColor(arcColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(identity.shortName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(identity.color)
                    // Status badge
                    let s = row?.status ?? .idle
                    Text(s.rawValue)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(s.color)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(s.color.opacity(0.15))
                        .cornerRadius(3)
                    Spacer()
                }
                if let r = row, !r.taskSummary.isEmpty {
                    Text(r.taskSummary)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }
                if let b = bench, b.progress > 0 {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(b.progress) / 100.0)
                            .progressViewStyle(.linear)
                            .tint(identity.color)
                            .frame(width: 80)
                        Text("\(b.progress)%")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                        if let cf = b.bestCF {
                            Text("CF=\(String(format:"%.1f",cf))")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(identity.color.opacity(0.7))
                        }
                        if let rm = b.bestRMSD {
                            Text("RMSD=\(String(format:"%.2f",rm))Å")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                }
                if !pet.lastTask.isEmpty {
                    Text("pet: \(pet.lastTask.prefix(60))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.5))
                }
            }

            Button(action: onDelegate) {
                Label("Delegate", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(identity.color)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(identity.color.opacity(0.12))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(identity.color.opacity(0.05))
    }
}

// MARK: - Agent Row Card

private struct AgentRowCard: View {
    let identity:   AgentIdentity
    let row:        AgentRow?
    let bench:      BenchmarkState?
    let pet:        PetState
    let onDelegate: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 2) {
                Text(identity.icon).font(.title3)
                Text(identity.shortName)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(identity.color.opacity(0.8))
            }
            .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(identity.shortName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(identity.color)
                    // Entropy mini-display — monospaced, always visible
                    if let ent = row?.entropy {
                        let c: Color = ent <= kH_threshold ? .red : ent < kH_block ? .orange : .white.opacity(0.35)
                        Text("H=\(String(format:"%.1f",ent))")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(c)
                    }
                    Spacer()
                    statusBadge
                }
                if let r = row, !r.taskSummary.isEmpty {
                    Text(r.taskSummary)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                }
                if let b = bench, b.progress > 0 {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(b.progress) / 100.0)
                            .progressViewStyle(.linear)
                            .tint(identity.color)
                            .frame(width: 80)
                        Text("\(b.progress)%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                        if let cf = b.bestCF {
                            Text("CF=\(String(format:"%.1f",cf))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(identity.color.opacity(0.7))
                        }
                    }
                }
                // Pet status line
                if !pet.lastTask.isEmpty {
                    Text("pet: \(pet.lastTask.prefix(50))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.5))
                }
            }

            Spacer()

            Button(action: onDelegate) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(identity.color.opacity(0.12)))
    }

    private var statusBadge: some View {
        let s = row?.status ?? .idle
        return Text(s.rawValue)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(s.color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(s.color.opacity(0.15))
            .cornerRadius(4)
    }
}

// MARK: - Status Bar Controller  (NSStatusItem — dots-only pill)

final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover:    NSPopover!
    private var hostingView: NSHostingView<HubPopoverView>?
    private let vm = HubViewModel()
    private var keyMonitor: Any?

    override init() {
        super.init()
        setupStatusItem()
        setupPopover()
        setupKeyboardMonitor()
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: Status Item — dots-only pill

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let btn = statusItem.button else { return }
        btn.target = self
        btn.action = #selector(togglePopover(_:))
        updatePill()

        // Re-draw pill every 2s to reflect live status
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updatePill() }
        }
    }

    private func updatePill() {
        guard let btn = statusItem.button else { return }
        let dots = AgentIdentity.all.map { a -> String in
            let status = vm.db.agents[a.id]?.status ?? .idle
            switch status {
            case .active:  return a.icon
            case .waiting: return "○"
            case .blocked: return "⊘"
            case .error:   return "✗"
            case .idle:    return "·"
            }
        }.joined(separator: " ")
        btn.title = dots
        btn.font  = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) }
        else              { showPopover() }
    }

    private func showPopover() {
        guard let btn = statusItem.button else { return }
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Popover setup

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior        = .transient
        popover.animates        = true
        popover.delegate        = self
        let content             = HubPopoverView(vm: vm)
        let hosting             = NSHostingController(rootView: content)
        popover.contentViewController = hosting
        popover.contentSize     = CGSize(width: 420, height: 580)
    }

    // MARK: Keyboard monitor  (directive H — Y/N/1-9/Tab/Space/Esc/⌘A/⌘Return)

    private func setupKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            return self.handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags
        let ch    = event.charactersIgnoringModifiers ?? ""

        // ⌘A — broadcast delegation
        if flags.contains(.command) && ch == "a" {
            vm.selectedAgent = nil
            vm.showDelegateBar = true
            return nil
        }
        // ⌘Return — submit delegation
        if flags.contains(.command) && event.keyCode == 36 {
            vm.submitDelegation()
            return nil
        }
        // ⌘Y — approve first interaction
        if flags.contains(.command) && ch == "y", let ia = vm.interactions.first {
            vm.resolveInteraction(ia.id, approved: true)
            SoundController.shared.play(event: "task_complete")
            return nil
        }
        // ⌘N — deny first interaction
        if flags.contains(.command) && ch == "n", let ia = vm.interactions.first {
            vm.resolveInteraction(ia.id, approved: false)
            return nil
        }
        // 1-9 — choice selection
        if let digit = Int(ch), (1...9).contains(digit), let ia = vm.interactions.first,
           case .choice(let opts) = ia.kind, digit <= opts.count {
            vm.resolveInteraction(ia.id, approved: true)
            return nil
        }
        // Space — toggle delegation bar
        if ch == " " && !flags.contains(.command) && !vm.showDelegateBar {
            vm.showDelegateBar = true
            return nil
        }
        // Escape — close delegate bar or popover
        if event.keyCode == 53 {
            if vm.showDelegateBar { vm.showDelegateBar = false; return nil }
            popover.performClose(nil)
            return nil
        }
        // Tab — cycle selected agent
        if ch == "\t" {
            cycleAgent()
            return nil
        }
        // Y / N without modifier — approve / deny
        if ch.lowercased() == "y" && !flags.contains(.command), let ia = vm.interactions.first {
            vm.resolveInteraction(ia.id, approved: true); return nil
        }
        if ch.lowercased() == "n" && !flags.contains(.command), let ia = vm.interactions.first {
            vm.resolveInteraction(ia.id, approved: false); return nil
        }

        return event
    }

    private func cycleAgent() {
        let ids = AgentIdentity.all.map(\.id)
        if let cur = vm.selectedAgent, let idx = ids.firstIndex(of: cur) {
            vm.selectedAgent = ids[(idx + 1) % ids.count]
        } else {
            vm.selectedAgent = ids.first
        }
    }

    // NSPopoverDelegate
    func popoverDidClose(_ notification: Notification) {
        vm.showDelegateBar = false
    }
}

// MARK: - App Entry Point

@main
struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No windows — pure menu bar app
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
        // Ensure ~/.shannon/ and pet directories exist
        PetManager.shared.ensureBaseDir()
        // Boot status bar
        statusBarController = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Mark any active agents as "resumable" in their pet state
        let db = AuditDBReader()
        for (id, row) in db.agents where row.status == .active {
            var state       = PetManager.shared.loadState(for: id)
            state.resumable = true
            state.status    = "mid_task"
            state.updatedAt = Date()
            PetManager.shared.saveState(state, for: id)
        }
    }
}
