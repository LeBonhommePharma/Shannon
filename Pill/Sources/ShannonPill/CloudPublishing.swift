import Foundation
import PillCore
import ShannonCore

/// Mac → iCloud publishing. Reads the same models the pill renders and mirrors
/// them into CloudKit for the iPhone and Apple Watch.
///
/// Publishing is best-effort by design: an unsigned `swift run` build has no
/// iCloud entitlement, and the pill must keep working regardless. Failures are
/// counted and exposed for the status line rather than surfaced as alerts.
@MainActor
final class CloudPublisher {
    private let publisher: ShannonPublisher
    private let deviceName: String
    private var timer: Timer?
    private let interval: TimeInterval

    private(set) var lastPublishedAt: Date?
    private(set) var failureCount = 0

    /// Sources are read at publish time rather than observed, so this stays a
    /// leaf: nothing in the pill has to know it exists.
    private weak var nowPlaying: NowPlayingModel?
    private weak var battery: BatteryMonitor?
    private weak var bridge: ShannonBridge?

    init(
        nowPlaying: NowPlayingModel?,
        battery: BatteryMonitor?,
        bridge: ShannonBridge?,
        backend: ShannonSyncBackend? = nil,
        interval: TimeInterval = 10,
        deviceName: String = Host.current().localizedName ?? "Mac"
    ) {
        self.nowPlaying = nowPlaying
        self.battery = battery
        self.bridge = bridge
        self.interval = interval
        self.deviceName = deviceName
        self.publisher = ShannonPublisher(backend: backend ?? CloudPublisher.defaultBackend())
    }

    /// Default backend is **always** in-memory unless the user opts into iCloud
    /// with `SHANNON_ICLOUD=1` *and* the process has a real iCloud entitlement.
    ///
    /// macOS 27 (and earlier): `CKContainer(identifier:)` raises `EXC_BREAKPOINT`
    /// when the container id is not in the app's entitlements. That is a hard
    /// process kill, not a catchable Swift error — so we must never construct
    /// `CloudKitSyncBackend` from an ad-hoc / Homebrew / `swift run` build.
    /// The previous code used `#if canImport(CloudKit)` which is true whenever
    /// the SDK is present, and crashed Shannon.app on every launch.
    private static func defaultBackend() -> ShannonSyncBackend {
        #if canImport(CloudKit)
        let optIn = ProcessInfo.processInfo.environment["SHANNON_ICLOUD"] == "1"
        if optIn, hasICloudEntitlement() {
            return CloudKitSyncBackend()
        }
        #endif
        return InMemorySyncBackend()
    }

    /// True only for a Developer-ID / App Store signed build that still ships
    /// an embedded provisioning profile with the iCloud capability. Ad-hoc
    /// Homebrew installs never have this file, so they always stay on the
    /// in-memory backend and never touch CKContainer.
    private static func hasICloudEntitlement() -> Bool {
        let candidates = [
            Bundle.main.bundlePath + "/Contents/embedded.provisionprofile",
            Bundle.main.bundlePath + "/embedded.provisionprofile",
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        publish()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One publish pass. `ShannonPublisher` suppresses unchanged records, so
    /// calling this on a timer does not burn the CloudKit request quota.
    func publish() {
        let media = nowPlayingSnapshot()
        let device = deviceSnapshot()
        let agent = agentSnapshot()

        Task { [publisher] in
            do {
                if let media { try await publisher.publish(nowPlaying: media) }
                if let device { try await publisher.publish(device) }
                if let agent { try await publisher.publish(agent) }
                // Playback taps made on the phone or watch come back here.
                let commands = try await publisher.consumeCommands()
                await MainActor.run {
                    self.lastPublishedAt = Date()
                    for command in commands { self.execute(command) }
                }
            } catch {
                await MainActor.run { self.failureCount += 1 }
            }
        }
    }

    // MARK: Model translation

    private func nowPlayingSnapshot() -> NowPlayingSnapshot? {
        guard let info = nowPlaying?.state.info else {
            // An explicit idle record is what clears the card on the phone;
            // omitting it would leave a stale track on screen forever.
            return NowPlayingSnapshot(title: "", artist: "")
        }
        return NowPlayingSnapshot(
            title: info.title,
            artist: info.artist,
            album: info.album,
            duration: info.duration,
            elapsed: info.elapsed,
            isPlaying: info.isPlaying,
            artworkJPEG: info.artworkData,
            sourceBundleID: info.sourceBundleID
        )
    }

    private func deviceSnapshot() -> MacDeviceState? {
        guard let snapshot = battery?.snapshot else { return nil }
        return MacDeviceState(
            deviceName: deviceName,
            batteryPercent: snapshot.percentage,
            isCharging: snapshot.isCharging,
            minutesRemaining: snapshot.isCharging
                ? snapshot.minutesToFull
                : snapshot.minutesToEmpty
        )
    }

    /// The Shannon coordination layer currently reports one aggregate entropy
    /// readout, which publishes as a single agent record. Per-agent records
    /// land when the bridge exposes them.
    private func agentSnapshot() -> AgentState? {
        guard let status = bridge?.status else { return nil }
        return AgentState(
            id: status.agent ?? "shannon-gate",
            name: status.agent ?? "Shannon gate",
            activity: status.collapsed ? .blocked : .running,
            taskTitle: "Entropy gate (\(status.backend))",
            turnCount: status.tokenCount,
            lastAction: status.collapsed ? "Entropy collapse detected" : "Monitoring",
            entropyBits: status.entropy,
            entropyDelta: status.deltaH,
            isCollapsed: status.collapsed
        )
    }

    // MARK: Inbound commands

    private func execute(_ command: RemoteCommand) {
        guard let nowPlaying else { return }
        switch command.command {
        case .togglePlayPause: nowPlaying.togglePlayPause()
        case .nextTrack:       nowPlaying.nextTrack()
        case .previousTrack:   nowPlaying.previousTrack()
        }
    }
}
