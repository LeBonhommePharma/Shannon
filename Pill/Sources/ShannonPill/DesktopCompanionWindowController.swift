// DesktopCompanionWindowController.swift — floating always-on-top pet + chat bubble.
//
// Separate from the notch PillPanel: this surface lives on the desktop, joins
// all Spaces, and re-asserts above normal app windows after space/focus changes.
// Content is driven by CompanionRoster + CompanionBubbleText (honest presence).

import AppKit
import Combine
import SwiftUI
import PillCore
import ShannonCore

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
        isOpaque = DesktopCompanionWindowPolicy.panelIsOpaque
        backgroundColor = .clear
        hasShadow = DesktopCompanionWindowPolicy.panelHasShadow
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
    /// How many agents are in the desktop cycle set (top N busy). E3.
    @Published private(set) var cycleCount: Int = 0
    /// Current slot within the cycle set (0-based). E3.
    @Published private(set) var selectedIndex: Int = 0

    private let activity: AgentActivityMonitor
    private let bridge: ShannonBridge
    private var cancellables = Set<AnyCancellable>()
    private var pollCancellable: AnyCancellable?
    private var currentPollInterval: TimeInterval?
    private var selectedAgentId: String?
    /// Forced package id (E1 picker); nil → selector default / B3 map.
    private var packagePetId: String?

    var scheduledPollIntervalForTesting: TimeInterval? { currentPollInterval }

    init(
        activity: AgentActivityMonitor,
        bridge: ShannonBridge,
        packagePetId: String? = nil
    ) {
        self.activity = activity
        self.bridge = bridge
        self.packagePetId = packagePetId
        let built = Self.makePresentation(
            activity: activity,
            bridge: bridge,
            preferredId: nil,
            fallbackIndex: 0,
            packagePetId: packagePetId
        )
        self.presentation = built.presentation
        self.selectedIndex = built.selectedIndex
        self.cycleCount = built.cycleCount
        self.selectedAgentId = built.presentation.state?.id
        bind()
        ensurePollTimer()
    }

    private func bind() {
        // Already on main via receive(on: RunLoop.main) — no extra async hop
        // (that delayed pet bubble/mood behind agent ticks).
        activity.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        bridge.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func setPackagePetId(_ id: String?) {
        if let id {
            packagePetId = ShannonPreferences.normalizeDesktopPetId(id)
        } else {
            packagePetId = nil
        }
        refresh()
    }

    func refresh() {
        apply(
            Self.makePresentation(
                activity: activity,
                bridge: bridge,
                preferredId: selectedAgentId,
                fallbackIndex: selectedIndex,
                packagePetId: packagePetId
            )
        )
        ensurePollTimer()
    }

    /// Advance to the next top-N busy agent (click cycle). No-op when ≤1.
    func cycleToNext() {
        let built = Self.makePresentation(
            activity: activity,
            bridge: bridge,
            preferredId: selectedAgentId,
            fallbackIndex: selectedIndex,
            packagePetId: packagePetId
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
                fallbackIndex: next,
                packagePetId: packagePetId
            )
        )
    }

    private func apply(_ built: DesktopCompanionCycle.PresentResult) {
        // Equality-gate so identical activity ticks do not thrash SwiftUI while
        // still publishing when mood / bubble / motion / agent identity flips.
        if presentation != built.presentation {
            presentation = built.presentation
        }
        if selectedIndex != built.selectedIndex {
            selectedIndex = built.selectedIndex
        }
        if cycleCount != built.cycleCount {
            cycleCount = built.cycleCount
        }
        selectedAgentId = built.presentation.state?.id
    }

    private func ensurePollTimer() {
        let interval = DesktopCompanionRefreshCadence.pollInterval(
            agents: activity.summary.agents,
            hasPendingAsk: !activity.pendingAsks.isEmpty
        )
        if currentPollInterval == interval, pollCancellable != nil { return }
        currentPollInterval = interval
        pollCancellable?.cancel()
        pollCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    static func makePresentation(
        activity: AgentActivityMonitor,
        bridge: ShannonBridge,
        preferredId: String?,
        fallbackIndex: Int,
        packagePetId: String?
    ) -> DesktopCompanionCycle.PresentResult {
        let summary = activity.summary
        let pendingIDs = Set(activity.pendingAsks.map(\.agentId))
        let admitted = LiveRosterAdmission.filterListed(
            agents: summary.agents,
            pendingAgentIDs: pendingIDs
        )
        let liveIds = Set(admitted.filter { $0.presence == .live }.map(\.id))
        let deltas = EntropyProvenance.companionDeltas(
            agentIds: admitted.map(\.id),
            bridgeConnected: bridge.connected,
            bridgeStatus: bridge.status,
            gate: activity.agentEntropy,
            gateDBAvailable: activity.gateDBAvailable,
            liveAgentIds: liveIds
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
            preferredId: preferredId,
            packagePetId: packagePetId
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
    /// When false, space/screen reassert must not resurrect the pet.
    private var shouldBeVisible = false

    private let activity: AgentActivityMonitor
    private let bridge: ShannonBridge
    /// Package id from Settings until the model is created (E1).
    private var initialPackagePetId: String?
    /// E4: click bubble/pet → expand notch + optional agent focus id.
    var onActivate: ((String?) -> Void)?

    /// Default size: pet + bubble + padding.
    static let defaultSize = CGSize(width: 200, height: 160)

    init(
        activity: AgentActivityMonitor,
        bridge: ShannonBridge,
        packagePetId: String? = nil
    ) {
        self.activity = activity
        self.bridge = bridge
        self.initialPackagePetId = packagePetId
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

    func setPackagePetId(_ id: String?) {
        initialPackagePetId = id
        model?.setPackagePetId(id)
    }

    func show() {
        shouldBeVisible = true
        let model = self.model ?? DesktopCompanionModel(
            activity: activity,
            bridge: bridge,
            packagePetId: initialPackagePetId
        )
        model.setPackagePetId(initialPackagePetId)
        self.model = model

        let size = Self.defaultSize
        let frame = Self.defaultFrame(size: size)

        let panel: DesktopCompanionPanel
        if let existing = self.panel {
            panel = existing
            if !existing.isVisible {
                panel.setFrame(frame, display: true)
            }
        } else {
            panel = DesktopCompanionPanel(contentRect: frame)
            panel.appearance = NSAppearance(named: .darkAqua)
            let root = DesktopCompanionHost(
                model: model,
                onActivate: { [weak self] in self?.performActivate() }
            )
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
    /// Delegates geometry to `DesktopCompanionWindowPolicy` so placement contracts
    /// stay unit-testable without a live window server.
    static func defaultFrame(size: CGSize, screen: NSScreen? = nil) -> CGRect {
        let scr = screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = scr?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        return DesktopCompanionWindowPolicy.defaultFrame(size: size, visibleFrame: visible)
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
                DesktopCompanionView(presentation: model.presentation)
            } else {
                DesktopCompanionLegacyView(presentation: model.presentation)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(8)
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .onTapGesture {
            model.cycleToNext()
            onActivate()
        }
        // UX-031: brand chrome shares Core quietShort (menu-bar/status a11y parity).
        .accessibilityHint(
            "Click to expand \(CompanionFocusCopy.quietShort) and focus this agent"
        )
        .accessibilityAction(
            named: Text("Open in \(CompanionFocusCopy.quietShort)")
        ) { onActivate() }
    }
}

/// Pre-macOS 14: SF Symbol pet + bubble (no Canvas companion art).
struct DesktopCompanionLegacyView: View {
    let presentation: DesktopCompanionPresentation

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            bubbleChrome(presentation.bubble)
            Image(systemName: "cat.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.shannonAccent)
                .frame(width: 72, height: 72)
        }
    }
}

// MARK: - Pet + bubble view

@available(macOS 14.0, *)
struct DesktopCompanionView: View {
    let presentation: DesktopCompanionPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            bubbleChrome(presentation.bubble)
            petBody
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Smooth bubble text swaps when agent / attention flips.
        .animation(
            reduceMotion ? nil : .shannonLiquid,
            value: presentation.bubble.text
        )
        .animation(
            reduceMotion ? nil : .shannonChrome,
            value: presentation.mood
        )
    }

    private var accessibilityLabel: String {
        let b = presentation.bubble
        if let d = b.detail {
            return "\(b.text). \(d)"
        }
        return b.text
    }

    @ViewBuilder
    private var petBody: some View {
        let size: CGFloat = 72
        // Policy: no mood-ring / stroke outline around the desktop pet sprite.
        let ring = DesktopCompanionWindowPolicy.petDrawsOutline
        if let state = presentation.state {
            CompanionBadge(
                state: state,
                size: size,
                reduceMotion: reduceMotion,
                showMoodRing: ring
            )
        } else if let kind = presentation.kind {
            // No hard black disc — pet sits in the desktop without sticker chrome.
            CompanionView(
                kind: kind,
                mood: presentation.mood,
                agentColor: Color.shannonAccent,
                size: size,
                codexMotion: presentation.motion,
                packagePetId: presentation.packagePetId,
                reduceMotion: reduceMotion
            )
        } else {
            Image(systemName: "cat.fill")
                .font(.system(size: size * 0.55))
                .foregroundStyle(Color.shannonAccent)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Shared bubble chrome
//
// Popover material + tint, continuous radius. **No strokeBorder outline** —
// status copy stays readable via fill contrast only (mood tints text when needed).

@ViewBuilder
private func bubbleChrome(_ b: CompanionBubbleContent) -> some View {
    let radius = CGFloat(DesktopCompanionWindowPolicy.bubbleCornerRadius)
    VStack(alignment: .leading, spacing: 2) {
        Text(b.text)
            .font(.shannonMenuBody)
            .foregroundStyle(bubblePrimaryColor(b))
        if let detail = b.detail {
            Text(detail)
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonSecondary)
                .lineLimit(2)
        }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background {
        ZStack {
            PillMaterial(kind: .popover)
            Color.shannonBackground.opacity(
                DesktopCompanionWindowPolicy.bubbleBackgroundTintOpacity
            )
        }
    }
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    // Outline only if policy re-enables it (default: false — no hairline ring).
    .overlay {
        if DesktopCompanionWindowPolicy.bubbleDrawsOutline {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(DesktopCompanionWindowPolicy.bubbleHairlineOpacity),
                    lineWidth: 0.5
                )
        }
    }
}

/// Mood-aware primary text (replaces former colored stroke as attention cue).
private func bubblePrimaryColor(_ b: CompanionBubbleContent) -> Color {
    if b.mood == .wary { return Color.shannonError }
    if b.motion == .waiting { return Color.shannonWarning }
    if b.claimsWork { return Color.shannonAccent }
    return Color.shannonPrimary
}
