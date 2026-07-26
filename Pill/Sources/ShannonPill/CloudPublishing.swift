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

    /// Honest multi-device status for the popover footer (P2.7).
    /// - `off` / `in-memory`: unsigned or SHANNON_ICLOUD≠1
    /// - `on`: CloudKit backend active
    private(set) var multiDeviceStatus: String = "in-memory"

    /// Sources are read at publish time rather than observed, so this stays a
    /// leaf: nothing in the pill has to know it exists.
    private weak var nowPlaying: NowPlayingModel?
    private weak var battery: BatteryMonitor?
    private weak var bridge: ShannonBridge?
    private weak var resources: SystemResourceMonitor?
    /// Source of the gate's pending approvals, mirrored to phone/watch/iPad and
    /// the sink the returning answers are applied to.
    private weak var activity: AgentActivityMonitor?

    /// Confirmation ids currently mirrored to iCloud, so a resolved ask can be
    /// retracted from every device rather than lingering.
    private var publishedConfirmationIDs: Set<String> = []

    /// Decides the `createdAt` each open ask is mirrored with — the gate's own
    /// `created_at_ns` where there is one, a stable local first-seen otherwise.
    /// See `ConfirmationCreatedAtResolver` for why both halves are needed.
    private var confirmationCreatedAt = ConfirmationCreatedAtResolver()

    init(
        nowPlaying: NowPlayingModel?,
        battery: BatteryMonitor?,
        bridge: ShannonBridge?,
        activity: AgentActivityMonitor? = nil,
        resources: SystemResourceMonitor? = nil,
        backend: ShannonSyncBackend? = nil,
        interval: TimeInterval = 10,
        deviceName: String = Host.current().localizedName ?? "Mac"
    ) {
        self.nowPlaying = nowPlaying
        self.battery = battery
        self.bridge = bridge
        self.activity = activity
        self.resources = resources
        self.interval = interval
        self.deviceName = deviceName
        let resolved = backend ?? CloudPublisher.defaultBackend()
        self.publisher = ShannonPublisher(backend: resolved)
        self.multiDeviceStatus = CloudPublisher.statusLabel(for: resolved)
    }

    /// Operator-facing label for the multi-device path.
    static func statusLabel(for backend: ShannonSyncBackend) -> String {
        let name = String(describing: type(of: backend))
        let cloudKit = name.contains("CloudKit")
        let optIn = MultiDeviceBackendPolicy.optInFromEnvironment()
        let profile = MultiDeviceBackendPolicy.hasEmbeddedProvisioningProfile()
        return MultiDeviceBackendPolicy.status(
            optIn: optIn,
            hasProvisioningProfile: profile,
            cloudKitConstructed: cloudKit
        ).rawValue
    }

    /// Default backend is **always** in-memory unless the user opts into iCloud
    /// with `SHANNON_ICLOUD=1` *and* the process has a real iCloud entitlement.
    ///
    /// macOS 27 (and earlier): `CKContainer(identifier:)` raises `EXC_BREAKPOINT`
    /// when the container id is not in the app's entitlements. That is a hard
    /// process kill, not a catchable Swift error — so we must never construct
    /// `CloudKitSyncBackend` from an ad-hoc / Homebrew / `swift run` build.
    /// Policy is pure in `MultiDeviceBackendPolicy` (unit-tested).
    private static func defaultBackend() -> ShannonSyncBackend {
        #if canImport(CloudKit)
        let optIn = MultiDeviceBackendPolicy.optInFromEnvironment()
        let profile = MultiDeviceBackendPolicy.hasEmbeddedProvisioningProfile()
        if MultiDeviceBackendPolicy.shouldUseCloudKit(
            optIn: optIn,
            hasProvisioningProfile: profile
        ) {
            return CloudKitSyncBackend()
        }
        #endif
        return InMemorySyncBackend()
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
        let now = Date()
        let confirmations = asks.map { ask -> PendingConfirmation in
            // Stable across passes, so an unchanged ask serialises to an
            // identical record and the publisher can suppress it — and anchored
            // to the gate's clock, so `expiresAt` counts from when the agent
            // actually asked rather than from this pill launch.
            PendingConfirmation(
                id: ask.interactionId,
                question: ask.prompt,
                agentID: ask.agentId,
                createdAt: confirmationCreatedAt.createdAt(for: ask, now: now)
            )
        }
        let liveIDs = Set(confirmations.map(\.id))
        let staleIDs = publishedConfirmationIDs.subtracting(liveIDs)
        publishedConfirmationIDs = liveIDs
        // Drop bookkeeping for asks the gate has cleared, so this cannot grow
        // without bound and a re-used interaction id starts fresh.
        confirmationCreatedAt.prune(keeping: liveIDs)

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
        // Host capacity (SSD/thermal/CPU/RAM) for multi-device load preference.
        let capacity = resources?.snapshot.hostCapacity
        return MacDeviceState(
            deviceName: deviceName,
            batteryPercent: snapshot.percentage,
            isCharging: snapshot.isCharging,
            minutesRemaining: snapshot.isCharging
                ? snapshot.minutesToFull
                : snapshot.minutesToEmpty,
            capacity: capacity
        )
    }

    /// The Shannon coordination layer currently reports one aggregate entropy
    /// readout, which publishes as a single agent record. Per-agent records
    /// land when the bridge exposes them.
    private func agentSnapshot() -> AgentState? {
        guard let bridge, let status = bridge.status else { return nil }
        // Same provenance rule as the pill's header, border, `~H` badge and
        // companion board (`EntropyProvenance`) — this is the surface that
        // actually leaves the machine, so it is the one that must not lie.
        //
        // `--demo` opens a REAL socket and serves `8.0 + 2.0*sin(n/12)`,
        // asserting `is_collapsed` on ~29% of ticks. Published raw, that lands
        // on the iPhone, Watch and iPad as `isCollapsed` (red readout) and
        // `activity == .blocked` ("Waiting on you") — and `AgentState` has no
        // provenance field, so `entropyLabel` renders "H 6.2" with none of the
        // pill's `~` marking. A fabricated number must therefore not be
        // published at all rather than published unmarked.
        let measured = EntropyProvenance.isMeasured(
            connected: bridge.connected, displayed: status
        )
        let collapsed = measured && status.collapsed
        return AgentState(
            id: status.agent ?? "shannon-gate",
            name: status.agent ?? "Shannon gate",
            activity: collapsed ? .blocked : .running,
            taskTitle: measured
                ? "Entropy gate (\(status.backend))"
                : "Entropy gate (simulated)",
            turnCount: status.tokenCount,
            lastAction: collapsed ? "Entropy collapse detected" : "Monitoring",
            entropyBits: measured ? status.entropy : nil,
            entropyDelta: measured ? status.deltaH : nil,
            isCollapsed: collapsed
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
