// DesktopCompanionWindowController.swift — floating always-on-top pet + chat bubble.
//
// Separate from the notch PillPanel: this surface lives on the desktop, joins
// all Spaces, and re-asserts above normal app windows after space/focus changes.
// Content is driven by CompanionRoster + CompanionBubbleText (honest presence).

import AppKit
import Combine
import SwiftUI
import PillCore

// MARK: - Panel

/// Borderless non-activating panel for the desktop companion.
/// Policy values come from `DesktopCompanionWindowPolicy` (unit-tested).
final class DesktopCompanionPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: DesktopCompanionWindowPolicy.styleMask,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: DesktopCompanionWindowPolicy.windowLevelRawValue)
        collectionBehavior = DesktopCompanionWindowPolicy.collectionBehavior
        isMovable = DesktopCompanionWindowPolicy.isMovable
        isMovableByWindowBackground = DesktopCompanionWindowPolicy.isMovableByWindowBackground
        hidesOnDeactivate = DesktopCompanionWindowPolicy.hidesOnDeactivate
        isReleasedWhenClosed = DesktopCompanionWindowPolicy.isReleasedWhenClosed
        alphaValue = 1.0
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { DesktopCompanionWindowPolicy.canBecomeKey }
    override var canBecomeMain: Bool { DesktopCompanionWindowPolicy.canBecomeMain }

    /// Apply / re-apply always-on-top policy (after Space changes, etc.).
    func applyAlwaysOnTopPolicy() {
        level = NSWindow.Level(rawValue: DesktopCompanionWindowPolicy.windowLevelRawValue)
        collectionBehavior = DesktopCompanionWindowPolicy.collectionBehavior
        hidesOnDeactivate = DesktopCompanionWindowPolicy.hidesOnDeactivate
        alphaValue = 1.0
    }
}

// MARK: - Model

/// Observable bridge from live activity → desktop presentation.
@MainActor
final class DesktopCompanionModel: ObservableObject {
    @Published private(set) var presentation: DesktopCompanionPresentation
    /// How many agents are in the desktop cycle set (top N busy).
    @Published private(set) var cycleCount: Int = 0
    /// Current slot within the cycle set (0-based).
    @Published private(set) var selectedIndex: Int = 0

    private let activity: AgentActivityMonitor
    private let bridge: ShannonBridge
    private var cancellables = Set<AnyCancellable>()
    /// Adaptive sleepy poll (O1) — not the fixed 2 s historical tick.
    private var pollCancellable: AnyCancellable?
    private var currentPollInterval: TimeInterval?
    /// Sticky agent id so a refresh keeps the same pet when the roster reorders.
    private var selectedAgentId: String?

    /// Last scheduled wall-timer interval (tests / diagnostics).
    var scheduledPollIntervalForTesting: TimeInterval? { currentPollInterval }

    init(activity: AgentActivityMonitor, bridge: ShannonBridge) {
        self.activity = activity
        self.bridge = bridge
        let built = Self.makePresentation(
            activity: activity,
            bridge: bridge,
            preferredId: nil,
            fallbackIndex: 0
        )
        self.presentation = built.presentation
        self.selectedIndex = built.selectedIndex
        self.cycleCount = built.cycleCount
        self.selectedAgentId = built.presentation.state?.id
        bind()
        ensurePollTimer()
    }

    private func bind() {
        // Activity + bridge ticks rebuild immediately; wall timer only covers
        // idle→sleepy age flips when gate traffic is quiet (see O1 cadence).
        activity.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)

        bridge.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
    }

    func refresh() {
        apply(
            Self.makePresentation(
                activity: activity,
                bridge: bridge,
                preferredId: selectedAgentId,
                fallbackIndex: selectedIndex
            )
        )
        ensurePollTimer()
    }

    /// Schedule / reschedule the sleepy poll from pure cadence policy.
    private func ensurePollTimer() {
        let interval = DesktopCompanionRefreshCadence.pollInterval(
            agents: activity.summary.agents
        )
        if currentPollInterval == interval, pollCancellable != nil { return }
        currentPollInterval = interval
        pollCancellable?.cancel()
        pollCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    /// Advance to the next top-N busy agent (click cycle). No-op when ≤1.
    func cycleToNext() {
        let built = Self.makePresentation(
            activity: activity,
            bridge: bridge,
            preferredId: selectedAgentId,
            fallbackIndex: selectedIndex
        )
        guard built.cycleCount > 1 else {
            apply(built)
            return
        }
        let next = DesktopCompanionCycle.nextIndex(
            after: built.selectedIndex,
            count: built.cycleCount
        )
        apply(
            Self.makePresentation(
                activity: activity,
                bridge: bridge,
                preferredId: nil,
                fallbackIndex: next
            )
        )
    }

    private func apply(_ built: DesktopCompanionCycle.PresentResult) {
        presentation = built.presentation
        selectedIndex = built.selectedIndex
        cycleCount = built.cycleCount
        selectedAgentId = built.presentation.state?.id
    }

    static func makePresentation(
        activity: AgentActivityMonitor,
        bridge: ShannonBridge,
        preferredId: String?,
        fallbackIndex: Int
    ) -> DesktopCompanionCycle.PresentResult {
        let summary = activity.summary
        let deltas = EntropyProvenance.companionDeltas(
            agentIds: summary.agents.map(\.id),
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status,
            gate: activity.agentEntropy,
            gateDBAvailable: activity.gateDBAvailable
        )
        let full = CompanionRoster.build(
            from: summary,
            entropyDeltas: deltas,
            pendingAsks: activity.pendingAsks,
            activity: activity.recentActivity
        )
        return DesktopCompanionCycle.present(
            roster: full,
            selectedIndex: fallbackIndex,
            preferredId: preferredId
        )
    }
}

// MARK: - Controller

@MainActor
final class DesktopCompanionWindowController {
    private var panel: DesktopCompanionPanel?
    private var model: DesktopCompanionModel?
    private var cancellables = Set<AnyCancellable>()
    private var reassertTimer: Timer?
    /// When false, space/screen reassert and capture flash must not resurrect the pet.
    private var shouldBeVisible = false

    private let activity: AgentActivityMonitor
    private let bridge: ShannonBridge

    /// E4: click bubble/pet → expand notch + optional agent focus id.
    var onActivate: ((String?) -> Void)?

    /// Default size: pet + bubble + padding.
    static let defaultSize = CGSize(width: 200, height: 160)

    init(activity: AgentActivityMonitor, bridge: ShannonBridge) {
        self.activity = activity
        self.bridge = bridge
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Whether the companion is intended to be shown (preference + last show/hide).
    var wantsVisible: Bool { shouldBeVisible }

    /// Panel instance when shown (tests / diagnostics).
    var panelForTesting: DesktopCompanionPanel? { panel }

    /// Exposed for tests / diagnostics — applied panel policy snapshot.
    var appliedPolicySnapshot: [String: String] {
        guard let panel else { return DesktopCompanionWindowPolicy.policySnapshot }
        var snap = DesktopCompanionWindowPolicy.policySnapshot
        let joins = panel.collectionBehavior.contains(.canJoinAllSpaces)
        let matches = DesktopCompanionWindowPolicy.matchesAlwaysOnTop(
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
        let model = self.model ?? DesktopCompanionModel(activity: activity, bridge: bridge)
        self.model = model

        let size = Self.defaultSize
        let frame = Self.defaultFrame(size: size)

        let panel: DesktopCompanionPanel
        if let existing = self.panel {
            panel = existing
            // Keep user drag position if already shown.
            if !existing.isVisible {
                panel.setFrame(frame, display: true)
            }
        } else {
            panel = DesktopCompanionPanel(contentRect: frame)
            panel.appearance = NSAppearance(named: .darkAqua)
            let root = DesktopCompanionHost(model: model, onActivate: { [weak self] in self?.performActivate() })
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: size)
            panel.contentView = host
            self.panel = panel

            if DesktopCompanionWindowPolicy.reassertOnScreenParametersChange {
                NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                    .sink { [weak self] _ in self?.reassertVisibility() }
                    .store(in: &cancellables)
            }
            if DesktopCompanionWindowPolicy.reassertOnActiveSpaceChange {
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

    /// Force the companion on top when the user wants it visible. No-op when hidden.
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
        let interval = DesktopCompanionWindowPolicy.launchReassertInterval
        let maxTicks = DesktopCompanionWindowPolicy.launchReassertTickCount
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

    /// User clicked bubble/pet — expand notch handoff with current agent focus (E4).
    func performActivate() {
        let focusId = model.map {
            DesktopCompanionHandoff.focusAgentId(from: $0.presentation)
        } ?? nil
        onActivate?(focusId)
    }

    /// Bottom-trailing corner of the preferred screen (with margin).
    static func defaultFrame(size: CGSize, screen: NSScreen? = nil) -> CGRect {
        let scr = screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = scr?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let margin: CGFloat = 24
        let x = visible.maxX - size.width - margin
        let y = visible.minY + margin
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// MARK: - SwiftUI host

/// Adaptive host for the window (macOS 13 package floor; Canvas pet on 14+).
struct DesktopCompanionHost: View {
    @ObservedObject var model: DesktopCompanionModel
    /// E4 handoff: expand notch + focus current agent.
    var onActivate: () -> Void = {}

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                DesktopCompanionView(
                    presentation: model.presentation,
                    cycleCount: model.cycleCount,
                    selectedIndex: model.selectedIndex,
                    onCycle: { model.cycleToNext() }
                )
            } else {
                DesktopCompanionLegacyView(
                    presentation: model.presentation,
                    cycleCount: model.cycleCount,
                    selectedIndex: model.selectedIndex,
                    onCycle: { model.cycleToNext() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(8)
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        // E4: click bubble/pet expands notch and focuses matching agent row.
        .onTapGesture { onActivate() }
        .accessibilityHint("Click to expand Shannon and focus this agent")
        .accessibilityAction(named: Text("Open in Shannon")) { onActivate() }
    }
}

struct DesktopCompanionLegacyView: View {
    let presentation: DesktopCompanionPresentation
    var cycleCount: Int = 0
    var selectedIndex: Int = 0
    var onCycle: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            bubbleChrome(presentation.bubble)
            Image(systemName: "cat.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.shannonAccent)
                .frame(width: 72, height: 72)
            if cycleCount > 1 {
                cycleDots(count: cycleCount, selected: selectedIndex)
                    .contentShape(Rectangle())
                    .onTapGesture { onCycle() }
            }
        }
    }
}

// MARK: - Pet + bubble view

@available(macOS 14.0, *)
struct DesktopCompanionView: View {
    let presentation: DesktopCompanionPresentation
    var cycleCount: Int = 0
    var selectedIndex: Int = 0
    var onCycle: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            bubbleChrome(presentation.bubble)
            petBody
            if cycleCount > 1 {
                cycleDots(count: cycleCount, selected: selectedIndex)
                    .contentShape(Rectangle())
                    .onTapGesture { onCycle() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let b = presentation.bubble
        var label: String
        if let d = b.detail {
            label = "\(b.text). \(d)"
        } else {
            label = b.text
        }
        if cycleCount > 1 {
            label += ". Agent \(selectedIndex + 1) of \(cycleCount)"
        }
        return label
    }

@ViewBuilder
    private var petBody: some View {
        let size: CGFloat = 72
        if let state = presentation.state {
            CompanionBadge(state: state, size: size, packagePetId: presentation.packagePetId)
        } else if let kind = presentation.kind {
            CompanionView(
                kind: kind,
                mood: presentation.mood,
                agentColor: Color.shannonAccent,
                size: size,
                codexMotion: presentation.motion,
                packagePetId: presentation.packagePetId
            )
            .background(
                Circle()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: size + 8, height: size + 8)
            )
        } else {
            Image(systemName: "cat.fill")
                .font(.system(size: size * 0.55))
                .foregroundStyle(Color.shannonAccent)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Cycle indicator (top-N multi-agent)

@ViewBuilder
private func cycleDots(count: Int, selected: Int) -> some View {
    HStack(spacing: 4) {
        ForEach(0..<count, id: \.self) { i in
            Circle()
                .fill(i == selected ? Color.shannonAccent : Color.white.opacity(0.28))
                .frame(width: 5, height: 5)
        }
    }
    .padding(.trailing, 2)
    .accessibilityHidden(true)
}

// MARK: - Shared bubble chrome

@ViewBuilder
private func bubbleChrome(_ b: CompanionBubbleContent) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(b.text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.primary)
        if let detail = b.detail {
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
        }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
    )
    .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(bubbleBorderColor(b), lineWidth: b.claimsWork ? 1.2 : 0.5)
    )
    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
}

private func bubbleBorderColor(_ b: CompanionBubbleContent) -> Color {
    if b.mood == .wary { return Color.shannonError.opacity(0.7) }
    if b.motion == .waiting { return Color.shannonWarning.opacity(0.7) }
    if b.claimsWork { return Color.shannonAccent.opacity(0.55) }
    return Color.white.opacity(0.12)
}
