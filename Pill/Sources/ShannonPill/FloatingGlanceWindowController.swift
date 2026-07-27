// FloatingGlanceWindowController.swift — pref-gated Mac fleet/usage glance (UX-058).
//
// Compact always-on-top NSPanel separate from the desktop pet. Content from
// MacFloatingGlance / FloatingGlance (fail-closed empty when nothing sourced).

import AppKit
import Combine
import SwiftUI
import PillCore
import ShannonCore

// MARK: - Panel

final class FloatingGlancePanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: FloatingGlanceWindowPolicy.styleMask,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: FloatingGlanceWindowPolicy.windowLevelRawValue)
        collectionBehavior = FloatingGlanceWindowPolicy.collectionBehavior
        isMovable = FloatingGlanceWindowPolicy.isMovable
        isMovableByWindowBackground = FloatingGlanceWindowPolicy.isMovableByWindowBackground
        hidesOnDeactivate = FloatingGlanceWindowPolicy.hidesOnDeactivate
        isReleasedWhenClosed = FloatingGlanceWindowPolicy.isReleasedWhenClosed
        alphaValue = 1.0
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { FloatingGlanceWindowPolicy.canBecomeKey }
    override var canBecomeMain: Bool { FloatingGlanceWindowPolicy.canBecomeMain }

    func applyAlwaysOnTopPolicy() {
        level = NSWindow.Level(rawValue: FloatingGlanceWindowPolicy.windowLevelRawValue)
        collectionBehavior = FloatingGlanceWindowPolicy.collectionBehavior
        hidesOnDeactivate = FloatingGlanceWindowPolicy.hidesOnDeactivate
        alphaValue = 1.0
    }
}

// MARK: - Model

@MainActor
final class FloatingGlanceModel: ObservableObject {
    @Published private(set) var presentation: FloatingGlancePresentation

    private let activity: AgentActivityMonitor
    private var cancellables = Set<AnyCancellable>()
    private var pollCancellable: AnyCancellable?
    /// Fail-closed usage map — only ids with real session tokens.
    private var usageByAgent: [String: AgentUsageSnapshot] = [:]
    private var lastUsageScan: Date = .distantPast
    /// Match closed parity cadence so glance does not thrash disk readers.
    private static let usageScanInterval: TimeInterval = 15

    init(activity: AgentActivityMonitor) {
        self.activity = activity
        self.presentation = MacFloatingGlance.present(
            agents: activity.summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity
        )
        bind()
        ensurePollTimer()
    }

    private func bind() {
        activity.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
    }

    func refresh() {
        presentation = MacFloatingGlance.present(
            agents: activity.summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity,
            usageByAgent: usageByAgent
        )
        maybeScanUsage()
        ensurePollTimer()
    }

    /// Inject usage for tests / shared parity without inventing tokens.
    func setUsageByAgentForTesting(_ map: [String: AgentUsageSnapshot]) {
        usageByAgent = map
        presentation = MacFloatingGlance.present(
            agents: activity.summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity,
            usageByAgent: usageByAgent
        )
    }

    private func maybeScanUsage() {
        let now = Date()
        guard now.timeIntervalSince(lastUsageScan) >= Self.usageScanInterval else { return }
        lastUsageScan = now
        let agents = activity.summary.agents
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Task.detached(priority: .utility) { [weak self] in
            let payload = ParityPanelModel.collectParityPayload(
                gateAgents: agents,
                now: now,
                home: home,
                includeArtifactReaders: true
            )
            let usage = SessionContentPresenter.usageByAgent(from: payload.sessionsByAgent)
            await self?.applyUsageMap(usage)
        }
    }

    /// Apply session-derived usage on the main actor (avoids Swift 6 self-capture).
    private func applyUsageMap(_ usage: [String: AgentUsageSnapshot]) {
        usageByAgent = usage
        presentation = MacFloatingGlance.present(
            agents: activity.summary.agents,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity,
            usageByAgent: usageByAgent
        )
    }

    private func ensurePollTimer() {
        if pollCancellable != nil { return }
        // Same band as desktop companion idle poll — activity.objectWillChange
        // already drives most updates; timer covers quiet usage rescans.
        pollCancellable = Timer.publish(every: 5.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }
}

// MARK: - Controller

@MainActor
final class FloatingGlanceWindowController {
    private var panel: FloatingGlancePanel?
    private var model: FloatingGlanceModel?
    private var cancellables = Set<AnyCancellable>()
    private var reassertTimer: Timer?
    private var shouldBeVisible = false

    private let activity: AgentActivityMonitor
    /// E4-style handoff: click glance → expand notch.
    var onActivate: (() -> Void)?

    static var defaultSize: CGSize {
        CGSize(
            width: FloatingGlanceWindowPolicy.defaultWidth,
            height: FloatingGlanceWindowPolicy.defaultHeight
        )
    }

    init(activity: AgentActivityMonitor) {
        self.activity = activity
    }

    var isVisible: Bool { panel?.isVisible == true }
    var wantsVisible: Bool { shouldBeVisible }
    var panelForTesting: FloatingGlancePanel? { panel }
    var modelForTesting: FloatingGlanceModel? { model }

    var appliedPolicySnapshot: [String: String] {
        guard let panel else { return FloatingGlanceWindowPolicy.policySnapshot }
        var snap = FloatingGlanceWindowPolicy.policySnapshot
        let joins = panel.collectionBehavior.contains(.canJoinAllSpaces)
        let matches = FloatingGlanceWindowPolicy.matchesAlwaysOnTop(
            levelRawValue: panel.level.rawValue,
            hidesOnDeactivate: panel.hidesOnDeactivate,
            canBecomeKey: panel.canBecomeKey,
            joinsAllSpaces: joins
        )
        snap["appliedLevel"] = "\(panel.level.rawValue)"
        snap["appliedHidesOnDeactivate"] = "\(panel.hidesOnDeactivate)"
        snap["appliedCanBecomeKey"] = "\(panel.canBecomeKey)"
        snap["appliedJoinsAllSpaces"] = "\(joins)"
        snap["appliedMatchesAlwaysOnTop"] = "\(matches)"
        return snap
    }

    func show() {
        shouldBeVisible = true
        let model = self.model ?? FloatingGlanceModel(activity: activity)
        self.model = model
        model.refresh()

        let size = Self.defaultSize
        let frame = Self.defaultFrame(size: size)

        let panel: FloatingGlancePanel
        if let existing = self.panel {
            panel = existing
            if !existing.isVisible {
                panel.setFrame(frame, display: true)
            }
        } else {
            panel = FloatingGlancePanel(contentRect: frame)
            panel.appearance = NSAppearance(named: .darkAqua)
            let root = FloatingGlanceHost(
                model: model,
                onActivate: { [weak self] in self?.onActivate?() }
            )
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: size)
            panel.contentView = host
            self.panel = panel

            if FloatingGlanceWindowPolicy.reassertOnScreenParametersChange {
                NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                    .sink { [weak self] _ in self?.reassertVisibility() }
                    .store(in: &cancellables)
            }
            if FloatingGlanceWindowPolicy.reassertOnActiveSpaceChange {
                NSWorkspace.shared.notificationCenter
                    .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                    .sink { [weak self] _ in self?.reassertVisibility() }
                    .store(in: &cancellables)
            }
        }

        applyFrontIfWanted()
        startLaunchReassertBurst()
    }

    func hide() {
        shouldBeVisible = false
        reassertTimer?.invalidate()
        reassertTimer = nil
        panel?.orderOut(nil)
    }

    func reassertVisibility() {
        guard shouldBeVisible else { return }
        guard panel != nil else {
            show()
            return
        }
        applyFrontIfWanted()
    }

    private func applyFrontIfWanted() {
        guard shouldBeVisible, let panel else { return }
        panel.applyAlwaysOnTopPolicy()
        panel.orderFrontRegardless()
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func startLaunchReassertBurst() {
        reassertTimer?.invalidate()
        var ticks = 0
        let interval = FloatingGlanceWindowPolicy.launchReassertInterval
        let maxTicks = FloatingGlanceWindowPolicy.launchReassertTickCount
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            Task { @MainActor in
                self?.reassertVisibility()
                ticks += 1
                if ticks >= maxTicks { timer.invalidate() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        reassertTimer = t
    }

    /// Top-trailing of preferred screen, stacked above the default pet corner.
    static func defaultFrame(size: CGSize, screen: NSScreen? = nil) -> CGRect {
        let scr = screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = scr?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let margin = FloatingGlanceWindowPolicy.screenMargin
        let stack = FloatingGlanceWindowPolicy.stackAboveCompanion
        let x = visible.maxX - size.width - margin
        let y = visible.minY + margin + stack
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// MARK: - SwiftUI host

struct FloatingGlanceHost: View {
    @ObservedObject var model: FloatingGlanceModel
    var onActivate: () -> Void = {}

    var body: some View {
        FloatingGlanceCard(presentation: model.presentation)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(8)
            .preferredColorScheme(.dark)
            .contentShape(Rectangle())
            .onTapGesture { onActivate() }
            .accessibilityIdentifier(FloatingGlance.accessibilityIdentifier)
            .accessibilityHint("Click to expand \(CompanionFocusCopy.quietShort)")
    }
}

struct FloatingGlanceCard: View {
    let presentation: FloatingGlancePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(FloatingGlance.title)
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonTertiary)
                .textCase(.uppercase)

            if presentation.isEmpty {
                Text(presentation.emptyCaption)
                    .font(.shannonMenuBody)
                    .foregroundStyle(Color.shannonSecondary)
                    .lineLimit(2)
            } else {
                if let fleet = presentation.fleetLine {
                    Text(fleet)
                        .font(.shannonMenuBody)
                        .foregroundStyle(Color.shannonPrimary)
                        .lineLimit(2)
                }
                if let usage = presentation.usageLine {
                    HStack(spacing: 4) {
                        Text(FloatingGlance.usageTitle)
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonTertiary)
                        Text(usage)
                            .font(.shannonMenuFootnote)
                            .foregroundStyle(Color.shannonAccent)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                PillMaterial(kind: .popover)
                Color.shannonBackground.opacity(0.35)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}
