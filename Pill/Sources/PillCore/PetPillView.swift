// PetPillView.swift — companion surfaces for the Shannon pill.
//
// WHAT THIS FILE USED TO BE, AND WHY IT CHANGED
//
// It held a single `PetPillView` bound to `ShannonCore.PetStore.shared` — one
// global pet for the whole machine, with a species, an XP bar and a level. Its
// mood came from `PetStore.computeMood(entropy:errorRate:idleSeconds:)`, which
// no call site ever invoked, so `pet.mood` sat on its hardcoded `.calm` default
// forever. The view itself was never instantiated anywhere in the app. It was a
// pet that had no agent, no mood and no viewer.
//
// It is now a *per-agent* companion, drawn with the artwork from
// `hub/Pet/PetRenderer.swift` and moved by the per-kind personality recovered
// from `stash@{0}`. Mood comes from `CompanionMood.resolve`, which can only
// reach `alert` on live gate telemetry.
//
// PLACEMENT RULE. Everything here is sized and toned for the EXPANDED board and
// the pet surfaces. Nothing in this file belongs in the collapsed pill: the
// collapsed pill was deliberately made recessive and translucent when idle, and
// a companion must not be the thing that undoes that. `CompanionBoardView`
// renders nothing at all when there is nothing worth showing.

#if canImport(SwiftUI)
import SwiftUI
import ShannonCore
import ShannonTheme

// MARK: - CompanionView

/// The drawn creature, and nothing else — no ring, no label, no chrome.
///
/// Motion is analytic (see `CompanionMotion`), so this view holds no `@State`
/// and never restarts its cycle. Every companion on screen reads the same
/// clock and therefore stays phase-locked.
@available(macOS 14.0, *)
public struct CompanionView: View {
    public let kind: CompanionKind
    public let mood: CompanionMood
    public let agentColor: Color
    public let size: CGFloat
    /// Instant the approval landed, for the one-shot `happy` bounce.
    public let happyStart: Date?
    /// Codex-aligned motion (atlas row). Defaults from mood when omitted.
    public let codexMotion: PetCodexMotion
    /// Optional Codex package pet id (e.g. "shannon"). When a v2 package is
    /// found, atlas frames are preferred; otherwise procedural Canvas art.
    public let packagePetId: String?
    /// Accessibility: static pose when the user prefers reduced motion.
    public let reduceMotion: Bool

    /// Resolved once per `packagePetId` — never on every TimelineView tick.
    @State private var cachedPackage: PetPackage?
    @State private var packageLookupDone = false

    public init(kind: CompanionKind,
                mood: CompanionMood,
                agentColor: Color,
                size: CGFloat = 26,
                happyStart: Date? = nil,
                codexMotion: PetCodexMotion? = nil,
                packagePetId: String? = PetPackageResolver.defaultPetId,
                reduceMotion: Bool = false) {
        self.kind = kind
        self.mood = mood
        self.agentColor = agentColor
        self.size = size
        self.happyStart = happyStart
        self.codexMotion = codexMotion ?? PetCodexMotion.from(mood: mood)
        self.packagePetId = packagePetId
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        Group {
            // Tick policy: Reduce Motion → static; active work → atlas FPS;
            // idle breathing → ~8 Hz (legacy 0.5 s freeze felt stuck).
            if let interval = PetMotionCadence.timelineInterval(
                mood: mood,
                motion: codexMotion,
                reduceMotion: reduceMotion
            ) {
                TimelineView(.periodic(from: .now, by: interval)) { tl in
                    content(at: tl.date)
                }
            } else {
                content(at: Date())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // the owning row carries the label
        .onAppear { resolvePackageOnce() }
        .onChange(of: packagePetId) { _ in
            packageLookupDone = false
            cachedPackage = nil
            resolvePackageOnce()
        }
    }

    /// Disk / pet.json resolve — only from appear / packagePetId change.
    private func resolvePackageOnce() {
        guard !packageLookupDone else { return }
        packageLookupDone = true
        guard let pid = packagePetId, !pid.isEmpty else {
            cachedPackage = nil
            return
        }
        let mode = CompanionDrawMode.resolve(petId: pid, motion: codexMotion)
        if case .atlas(let package, _) = mode {
            cachedPackage = package
        } else {
            cachedPackage = nil
        }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        // Prefer atlas only when crop succeeds this frame; otherwise procedural
        // so a corrupt/missing sheet never blanks the companion.
        if let package = cachedPackage,
           let cg = PetAtlasRenderer.frameImage(
               package: package, motion: codexMotion, tSeconds: t
           ) {
            Canvas { ctx, sz in
                ctx.draw(Image(decorative: cg, scale: 1), in: CGRect(origin: .zero, size: sz))
            }
        } else {
            proceduralCanvas(at: date)
        }
    }

    private func proceduralCanvas(at date: Date) -> some View {
        Canvas { ctx, sz in
            let frame = CompanionMotion.frame(
                kind: kind,
                mood: mood,
                t: date.timeIntervalSinceReferenceDate,
                happyElapsed: happyStart.map { date.timeIntervalSince($0) } ?? 0
            )
            CompanionArt.draw(kind: kind,
                              frame: frame,
                              palette: kind.palette,
                              agentColor: agentColor,
                              in: &ctx,
                              size: sz)
        }
        // Keep body transforms inside the glyph box (no scatter overflow).
        .clipped()
    }
}

// MARK: - CompanionGlyph

/// A companion, or the agent's SF Symbol when that pet has no artwork.
///
/// The fallback is deliberate and inherited from the original design: a missing
/// drawing must never silently render as the wrong animal. Parrot, tortoise,
/// gecko, cat and ladybug agents therefore keep their symbol until someone
/// draws them.
@available(macOS 14.0, *)
public struct CompanionGlyph: View {
    public let state: CompanionState
    public let size: CGFloat
    /// Optional force package id (user preference / surface). `nil` → map from agent.
    public let packagePetIdOverride: String?
    public let reduceMotion: Bool

    public init(
        state: CompanionState,
        size: CGFloat = 26,
        packagePetId: String? = nil,
        reduceMotion: Bool = false
    ) {
        self.state = state
        self.size = size
        self.packagePetIdOverride = packagePetId
        self.reduceMotion = reduceMotion
    }

    private var style: AgentStyle { AgentStyleCatalog.style(for: state.agent.id) }

    /// Atlas package for this agent (B3) — not always `"shannon"`.
    public var packagePetId: String {
        PetPackageResolver.preferredPackageId(
            forAgentId: state.agent.id,
            preferenceOverride: packagePetIdOverride,
            style: style
        )
    }

    public var body: some View {
        if let kind = state.kind {
            CompanionView(kind: kind,
                          mood: state.mood,
                          agentColor: style.color,
                          size: size,
                          happyStart: happyStart,
                          codexMotion: state.codexMotion,
                          packagePetId: packagePetId,
                          reduceMotion: reduceMotion)
        } else {
            Image(systemName: state.symbolFallback)
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(style.palette.ink)
                .frame(width: size, height: size)
                .opacity(state.mood == .sleepy ? 0.45 : 0.9)
                .accessibilityHidden(true)
        }
    }

    /// Reconstruct the approval instant the mood was resolved against.
    private var happyStart: Date? {
        state.happyElapsed.map { Date().addingTimeInterval(-$0) }
    }
}

// MARK: - CompanionBadge

/// Companion inside a mood ring. The ring is the *only* thing that changes with
/// mood at a glance, and it is nearly invisible when the agent is idle.
@available(macOS 14.0, *)
public struct CompanionBadge: View {
    public let state: CompanionState
    public let size: CGFloat
    public let packagePetIdOverride: String?
    public let reduceMotion: Bool
    /// Mood ring stroke around the pet. Desktop companion sets false (no outline).
    public let showMoodRing: Bool

    public init(
        state: CompanionState,
        size: CGFloat = 26,
        packagePetId: String? = nil,
        reduceMotion: Bool = false,
        showMoodRing: Bool = true
    ) {
        self.state = state
        self.size = size
        self.packagePetIdOverride = packagePetId
        self.reduceMotion = reduceMotion
        self.showMoodRing = showMoodRing
    }

    public var body: some View {
        ZStack {
            if showMoodRing {
                Circle()
                    .strokeBorder(
                        state.mood.ringColor.opacity(state.mood.ringOpacity),
                        lineWidth: state.mood == .wary ? 1.6 : 1
                    )
            }
            CompanionGlyph(
                state: state,
                size: showMoodRing ? size * 0.86 : size,
                packagePetId: packagePetIdOverride,
                reduceMotion: reduceMotion
            )
        }
        .frame(width: size, height: size)
    }
}

// MARK: - CompanionRow

/// One agent on the expanded board: companion, name, and the honest status.
///
/// The mood word and the status line always appear together. The companion
/// restates the agent's state more softly; it is never the only place that
/// state appears, and it never says something `statusLine` does not support.
///
/// Optional `density` (project · branch · model + usage) comes from the same
/// `SessionContentPresenter` path as the macOS 13 `agentRow` fallback — never
/// invent tokens or meta when sessions omit them.
@available(macOS 14.0, *)
public struct CompanionRow: View {
    public let state: CompanionState
    /// Desktop-pet handoff (E4): true when this row matches the focused agent.
    public var isFocused: Bool
    /// Fail-closed session density (meta + usage short label).
    public var density: CompanionBoardDensity

    public init(
        state: CompanionState,
        isFocused: Bool = false,
        density: CompanionBoardDensity = CompanionBoardDensity()
    ) {
        self.state = state
        self.isFocused = isFocused
        self.density = density
    }

    private var style: AgentStyle { AgentStyleCatalog.style(for: state.agent.id) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        HStack(spacing: 8) {
            CompanionBadge(state: state, size: 26, reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(state.agent.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(style.palette.ink)
                        .lineLimit(1)

                    // Tenure, shown only once the pet has actually earned it.
                    if state.bond > .fresh {
                        Text(state.bond.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(style.palette.wash))
                    }

                    if let usage = density.usageLabel {
                        Text(usage)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                // The evidence, verbatim, never the pet's opinion of it.
                Text(state.agent.statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Project · branch · model — only when a session source reported them.
                if let meta = density.metaLine {
                    Text(meta)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            // T3: motion-honest word (review/failed never show resting/sleeping).
            Text(state.moodDisplayWord)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(moodWordStyle)
                .lineLimit(1)
        }
        .padding(.horizontal, isFocused ? 6 : 0)
        .padding(.vertical, isFocused ? 4 : 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.shannonAccent.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.shannonAccent.opacity(0.55) : Color.clear,
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityCombined))
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private var accessibilityCombined: String {
        var parts = [state.accessibilityLine]
        if let usage = density.usageLabel { parts.append(usage) }
        if let meta = density.metaLine { parts.append(meta) }
        return parts.joined(separator: ", ")
    }

    /// Quiet tertiary only when both procedural mood and codex motion are idle-ish.
    private var moodWordStyle: AnyShapeStyle {
        switch state.codexMotion {
        case .failed:
            return AnyShapeStyle(CompanionMood.wary.ringColor)
        case .review:
            return AnyShapeStyle(Color.secondary)
        default:
            if state.mood == .idle || state.mood == .sleepy {
                return AnyShapeStyle(.tertiary)
            }
            return AnyShapeStyle(state.mood.ringColor)
        }
    }
}

// MARK: - CompanionBoardView

/// The companion roster for the EXPANDED board.
///
/// Renders nothing when there are no agents, so dropping it into the board
/// costs zero pixels on a quiet machine.
///
/// `densityByAgent` is the AgentNotch/AgentPeek-class session content overlay
/// (project · branch · model + usage). Built by `SessionContentPresenter` from
/// real sessions only — never invents fields.
@available(macOS 14.0, *)
public struct CompanionBoardView: View {
    public let states: [CompanionState]
    public let maxRows: Int
    /// Desktop-pet handoff (E4): agent id to highlight, if any.
    public var focusedAgentId: String?
    /// Per-agent meta + usage from sessions (fail-closed).
    public var densityByAgent: [String: CompanionBoardDensity]
    /// Session cwd by agent id for jump-to-host fallback (ENH-028). Fail-closed empty.
    public var cwdByAgent: [String: String]

    public init(
        states: [CompanionState],
        maxRows: Int = 6,
        focusedAgentId: String? = nil,
        densityByAgent: [String: CompanionBoardDensity] = [:],
        cwdByAgent: [String: String] = [:]
    ) {
        self.states = states
        self.maxRows = maxRows
        self.focusedAgentId = focusedAgentId
        self.densityByAgent = densityByAgent
        self.cwdByAgent = cwdByAgent
    }

    /// Convenience: build straight from an activity summary.
    public init(summary: AgentActivitySummary,
                now: Date = Date(),
                approvals: [String: Date] = [:],
                entropyDeltas: [String: Double] = [:],
                entropyDelta: Double? = nil,
                pendingAsks: [GateDBReader.PendingAsk] = [],
                lastOutcomes: [String: String] = [:],
                activity: [GateDBReader.ActivityEvent] = [],
                maxRows: Int = 6,
                focusedAgentId: String? = nil,
                densityByAgent: [String: CompanionBoardDensity] = [:],
                cwdByAgent: [String: String] = [:]) {
        self.states = CompanionRoster.build(from: summary,
                                            now: now,
                                            approvals: approvals,
                                            entropyDeltas: entropyDeltas,
                                            entropyDelta: entropyDelta,
                                            pendingAsks: pendingAsks,
                                            lastOutcomes: lastOutcomes,
                                            activity: activity)
        self.maxRows = maxRows
        self.focusedAgentId = focusedAgentId
        self.densityByAgent = densityByAgent
        self.cwdByAgent = cwdByAgent
    }

    public var body: some View {
        if states.isEmpty {
            EmptyView()
        } else {
            // UX-057: three status sections (needs-you / working / done), then
            // quiet rows. Cap total visible rows at maxRows across the board.
            let visible = Array(states.prefix(maxRows))
            let buckets = StatusBoardColumns.partition(visible) { $0.statusBoardColumn }
            VStack(alignment: .leading, spacing: 6) {
                if buckets.hasColumnContent {
                    ForEach(StatusBoardColumns.displayOrder, id: \.self) { column in
                        let columnStates = buckets.agents(in: column)
                        if !columnStates.isEmpty {
                            statusBoardSection(column: column, states: columnStates)
                        }
                    }
                }
                if !buckets.other.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(buckets.other) { state in
                            companionBoardRow(state)
                        }
                    }
                }
                // Flat fallback when every row is "other" and we hid sections:
                // still show them (handled above). When nothing was column-mapped
                // and other is also empty, we already returned EmptyView.
                if !buckets.hasColumnContent, buckets.other.isEmpty {
                    // Defensive: partition always places each item somewhere.
                    ForEach(visible) { state in
                        companionBoardRow(state)
                    }
                }
                if states.count > maxRows {
                    Text("+\(states.count - maxRows) more")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 34)
                }
            }
        }
    }

    @ViewBuilder
    private func statusBoardSection(
        column: StatusBoardColumn,
        states: [CompanionState]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(StatusBoardColumns.title(for: column))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(StatusBoardColumns.accessibilityIdentifier(for: column))
            ForEach(states) { state in
                companionBoardRow(state)
            }
        }
    }

    private func companionBoardRow(_ state: CompanionState) -> some View {
        CompanionRow(
            state: state,
            isFocused: DesktopCompanionHandoff.isFocusedRow(
                rowAgentId: state.id,
                focusedAgentId: focusedAgentId
            ),
            density: densityByAgent[state.id] ?? CompanionBoardDensity()
        )
        .contextMenu {
            // ENH-028: resolve only when the menu opens (no per-frame NSWorkspace scan).
            let action = HostTerminalJumpPolicy.decide(
                input: HostTerminalJumpInput(
                    hostBundleID: state.agent.attachBundle,
                    attachPid: state.agent.attachPid,
                    cwd: cwdByAgent[state.id]
                ),
                runningBundleIDs: HostTerminalJumpExecutor.runningBundleIDs()
            )
            if action.isAvailable {
                Button(action.affordanceLabel) {
                    _ = HostTerminalJumpExecutor.perform(action)
                }
            }
        }
    }
}

// MARK: - Previews

@available(macOS 14.0, *)
#Preview("Companion gallery") {
    let now = Date()
    return VStack(alignment: .leading, spacing: 10) {
        ForEach(CompanionKind.allCases, id: \.self) { kind in
            HStack(spacing: 10) {
                Text(kind.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 60, alignment: .leading)
                ForEach(CompanionMood.allCases, id: \.self) { mood in
                    VStack(spacing: 2) {
                        CompanionView(kind: kind, mood: mood,
                                      agentColor: .orange, size: 40,
                                      happyStart: mood == .happy ? now : nil)
                        Text(mood.label)
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    .padding(16)
}

#endif
