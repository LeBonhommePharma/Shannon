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

    public init(kind: CompanionKind,
                mood: CompanionMood,
                agentColor: Color,
                size: CGFloat = 26,
                happyStart: Date? = nil) {
        self.kind = kind
        self.mood = mood
        self.agentColor = agentColor
        self.size = size
        self.happyStart = happyStart
    }

    public var body: some View {
        Group {
            // A companion with nothing to report costs a redraw every 500 ms
            // instead of one every frame. Idle is the overwhelmingly common
            // case, and the pill has no business burning a display link on a
            // breathing owl.
            if mood == .idle || mood == .sleepy {
                TimelineView(.periodic(from: .now, by: 0.5)) { tl in canvas(at: tl.date) }
            } else {
                TimelineView(.animation) { tl in canvas(at: tl.date) }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // the owning row carries the label
    }

    private func canvas(at date: Date) -> some View {
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

    public init(state: CompanionState, size: CGFloat = 26) {
        self.state = state
        self.size = size
    }

    private var style: AgentStyle { AgentStyleCatalog.style(for: state.agent.id) }

    public var body: some View {
        if let kind = state.kind {
            CompanionView(kind: kind,
                          mood: state.mood,
                          agentColor: style.color,
                          size: size,
                          happyStart: happyStart)
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

    public init(state: CompanionState, size: CGFloat = 26) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(state.mood.ringColor.opacity(state.mood.ringOpacity),
                              lineWidth: state.mood == .wary ? 1.6 : 1)
            CompanionGlyph(state: state, size: size * 0.86)
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
@available(macOS 14.0, *)
public struct CompanionRow: View {
    public let state: CompanionState

    public init(state: CompanionState) { self.state = state }

    private var style: AgentStyle { AgentStyleCatalog.style(for: state.agent.id) }

    public var body: some View {
        HStack(spacing: 8) {
            CompanionBadge(state: state, size: 26)

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
                }

                // The evidence, verbatim, never the pet's opinion of it.
                Text(state.agent.statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(state.mood.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(state.mood == .idle || state.mood == .sleepy
                                 ? AnyShapeStyle(.tertiary)
                                 : AnyShapeStyle(state.mood.ringColor))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(state.accessibilityLine))
    }
}

// MARK: - CompanionBoardView

/// The companion roster for the EXPANDED board.
///
/// Renders nothing when there are no agents, so dropping it into the board
/// costs zero pixels on a quiet machine.
@available(macOS 14.0, *)
public struct CompanionBoardView: View {
    public let states: [CompanionState]
    public let maxRows: Int

    public init(states: [CompanionState], maxRows: Int = 6) {
        self.states = states
        self.maxRows = maxRows
    }

    /// Convenience: build straight from an activity summary.
    public init(summary: AgentActivitySummary,
                now: Date = Date(),
                approvals: [String: Date] = [:],
                entropyDeltas: [String: Double] = [:],
                entropyDelta: Double? = nil,
                maxRows: Int = 6) {
        self.states = CompanionRoster.build(from: summary,
                                            now: now,
                                            approvals: approvals,
                                            entropyDeltas: entropyDeltas,
                                            entropyDelta: entropyDelta)
        self.maxRows = maxRows
    }

    public var body: some View {
        if states.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(states.prefix(maxRows)) { state in
                    CompanionRow(state: state)
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
