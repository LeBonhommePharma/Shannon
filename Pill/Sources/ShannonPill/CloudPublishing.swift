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
    /// Source of the gate's pending approvals, mirrored to phone/watch/iPad and
    /// the sink the returning answers are applied to.
    private weak var activity: AgentActivityMonitor?

    /// Confirmation ids currently mirrored to iCloud, so a resolved ask can be
    /// retracted from every device rather than lingering.
    private var publishedConfirmationIDs: Set<String> = []

    init(
        nowPlaying: NowPlayingModel?,
        battery: BatteryMonitor?,
        bridge: ShannonBridge?,
        activity: AgentActivityMonitor? = nil,
        backend: ShannonSyncBackend? = nil,
        interval: TimeInterval = 10,
        deviceName: String = Host.current().localizedName ?? "Mac"
    ) {
        self.nowPlaying = nowPlaying
        self.battery = battery
        self.bridge = bridge
        self.activity = activity
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
        // The gate's open approvals, mirrored so phone/watch/iPad can answer.
        // id == interaction_id so a returning ConfirmationResponse resolves the
        // exact gate row; agentID carries what the socket write needs.
        let asks = activity?.pendingAsks ?? []
        let confirmations = asks.map { ask in
            PendingConfirmation(
                id: ask.interactionId,
                question: ask.prompt,
                agentID: ask.agentId
            )
        }
        let liveIDs = Set(confirmations.map(\.id))
        let staleIDs = publishedConfirmationIDs.subtracting(liveIDs)
        publishedConfirmationIDs = liveIDs

        Task { [publisher] in
            do {
                if let media { try await publisher.publish(nowPlaying: media) }
                if let device { try await publisher.publish(device) }
                if let agent { try await publisher.publish(agent) }

                // Mirror open approvals, and retract the ones the gate cleared so
                // a resolved card vanishes from every device.
                for confirmation in confirmations {
                    try await publisher.publish(confirmation)
                }
                for id in staleIDs {
                    try await publisher.retract(
                        PendingConfirmation(id: id, question: "")
                    )
                }

                // Playback taps made on the phone or watch come back here.
                let commands = try await publisher.consumeCommands()
                // Answers to pending questions made off the desk come back here;
                // forwarding them to the gate socket is the link that actually
                // unblocks the waiting agent.
                let answers = try await publisher.consumeConfirmationResponses()
                await MainActor.run {
                    self.lastPublishedAt = Date()
                    for command in commands { self.execute(command) }
                    for (response, confirmation) in answers {
                        self.applyRemoteAnswer(response, confirmation)
                    }
                }
            } catch {
                await MainActor.run { self.failureCount += 1 }
            }
        }
    }

    /// Forward a phone/watch/iPad answer to the gate socket, then drop the local
    /// ask so the pill stops pulsing without waiting for the next DB poll.
    private func applyRemoteAnswer(
        _ response: ConfirmationResponse,
        _ confirmation: PendingConfirmation?
    ) {
        // agentID is required to resolve the gate row; without it the socket
        // write can't be addressed, so we drop the answer rather than guess.
        guard let agentID = confirmation?.agentID, !agentID.isEmpty else { return }
        let interactionID = response.id
        let approved = response.answer == .confirmed
        publishedConfirmationIDs.remove(interactionID)
        Task { [weak self] in
            _ = try? await GateApprovalClient.resolveAsync(
                interactionId: interactionID,
                agentId: agentID,
                approved: approved
            )
            await MainActor.run { self?.activity?.clearAsk(interactionID) }
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
