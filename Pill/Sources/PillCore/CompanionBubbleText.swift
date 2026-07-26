// CompanionBubbleText.swift — pure chat/status bubble copy for desktop companions.
//
// Honesty rules match CompanionMood / PetCodexMotion:
//   - Live gate telemetry may claim work (running / focused).
//   - Observed / offline must never launder into busy/running claims.
//   - Collapse / failed outrank celebration.
//   - Pending ask → waiting language, not "working".
//
// Pure Foundation only so unit tests need no AppKit / window server.

import Foundation

/// Text shown in the desktop companion chat/status bubble.
public struct CompanionBubbleContent: Sendable, Equatable {
    /// Primary line inside the bubble (short, scannable).
    public let text: String
    /// Optional secondary line (task snippet or evidence).
    public let detail: String?
    /// True only when the bubble asserts the agent is doing work.
    public let claimsWork: Bool
    /// Motion vocabulary that drove this copy (for tests / accessibility).
    public let motion: PetCodexMotion
    /// Mood that drove this copy.
    public let mood: CompanionMood

    public init(
        text: String,
        detail: String? = nil,
        claimsWork: Bool,
        motion: PetCodexMotion,
        mood: CompanionMood
    ) {
        self.text = text
        self.detail = detail
        self.claimsWork = claimsWork
        self.motion = motion
        self.mood = mood
    }
}

/// Derives honest bubble text from companion / gate signals.
public enum CompanionBubbleText {

    /// Inputs for bubble derivation (no AppKit).
    public struct Signals: Sendable, Equatable {
        public var presence: AgentPresence
        public var status: AgentRunStatus
        public var mood: CompanionMood
        public var motion: PetCodexMotion
        public var displayName: String
        public var statusLine: String
        public var lastTask: String
        public var hasPendingAsk: Bool
        public var lastOutcome: String?

        public init(
            presence: AgentPresence = .observed,
            status: AgentRunStatus = .idle,
            mood: CompanionMood = .idle,
            motion: PetCodexMotion = .idle,
            displayName: String = "Agent",
            statusLine: String = "",
            lastTask: String = "",
            hasPendingAsk: Bool = false,
            lastOutcome: String? = nil
        ) {
            self.presence = presence
            self.status = status
            self.mood = mood
            self.motion = motion
            self.displayName = displayName
            self.statusLine = statusLine
            self.lastTask = lastTask
            self.hasPendingAsk = hasPendingAsk
            self.lastOutcome = lastOutcome
        }

        public init(state: CompanionState) {
            self.presence = state.agent.presence
            self.status = state.agent.status
            self.mood = state.mood
            self.motion = state.codexMotion
            self.displayName = state.agent.displayName
            self.statusLine = state.agent.statusLine
            self.lastTask = state.agent.lastTask
            self.hasPendingAsk = state.codexMotion == .waiting
            // B2: keep roster/activity outcomes so review/failed detail can restate them.
            self.lastOutcome = state.lastOutcome
        }
    }

    /// Default bubble when no agents are on the roster (Shannon still watches).
    public static let emptyRosterText = "Watching…"
    public static let emptyRosterDetail: String? = "No live agents"

    /// Derive bubble content. Never invents busy claims for non-live presence.
    public static func derive(_ signals: Signals) -> CompanionBubbleContent {
        let name = signals.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = name.isEmpty ? "Agent" : name
        let task = softTask(signals.lastTask)
        let motion = signals.motion
        let mood = signals.mood

        // 1. Collapse / failed — outranks celebration and work claims.
        // Mood is always wary so copy never launders as idle/resting (T3).
        if motion == .failed || mood == .wary {
            return CompanionBubbleContent(
                text: "Something feels off",
                detail: nonWorkDetail(
                    who: who,
                    statusLine: signals.statusLine,
                    task: task,
                    lastOutcome: signals.lastOutcome
                ),
                claimsWork: false,
                motion: .failed,
                mood: .wary
            )
        }

        // 2. Waiting / pending ask — never "working".
        if motion == .waiting || signals.hasPendingAsk || signals.status == .blocked {
            return CompanionBubbleContent(
                text: "Needs you",
                detail: task ?? "Waiting for approval",
                claimsWork: false,
                motion: .waiting,
                mood: mood
            )
        }

        // 3. Approval celebration — short, not a work claim.
        if motion == .waving || motion == .jumping || mood == .happy {
            return CompanionBubbleContent(
                text: "Approved!",
                detail: who,
                claimsWork: false,
                motion: motion == .jumping ? .jumping : .waving,
                mood: .happy
            )
        }

        // 4. Live work only when motion/mood honestly claim it.
        let mayClaimWork = signals.presence.canBeBusy
            && (motion.claimsWork || mood.claimsWork)
        if mayClaimWork {
            return CompanionBubbleContent(
                text: "On it",
                detail: task ?? who,
                claimsWork: true,
                motion: .running,
                mood: .alert
            )
        }

        // 5. Review — finished, not busy. Prefer task, else outcome evidence.
        if motion == .review {
            return CompanionBubbleContent(
                text: "Ready for review",
                detail: task ?? outcomeEvidence(signals.lastOutcome) ?? who,
                claimsWork: false,
                motion: .review,
                mood: mood
            )
        }

        // 6. Offline — must not look busy.
        if signals.presence == .offline || mood == .sleepy {
            return CompanionBubbleContent(
                text: "Sleeping",
                detail: softStatus(signals.statusLine) ?? who,
                claimsWork: false,
                motion: .idle,
                mood: .sleepy
            )
        }

        // 7. Observed (window focus only) — rest, never work.
        if signals.presence == .observed {
            return CompanionBubbleContent(
                text: "Resting",
                detail: softStatus(signals.statusLine) ?? "Seen nearby",
                claimsWork: false,
                motion: .idle,
                mood: mood == .sleepy ? .sleepy : .idle
            )
        }

        // 8. Live idle / default rest.
        return CompanionBubbleContent(
            text: "Resting",
            detail: task ?? who,
            claimsWork: false,
            motion: .idle,
            mood: mood == .sleepy ? .sleepy : .idle
        )
    }

    /// Convenience over a resolved companion state.
    public static func derive(from state: CompanionState) -> CompanionBubbleContent {
        derive(Signals(state: state))
    }

    /// Bubble when the desktop surface has no agents to show.
    public static func emptyRoster() -> CompanionBubbleContent {
        CompanionBubbleContent(
            text: emptyRosterText,
            detail: emptyRosterDetail,
            claimsWork: false,
            motion: .idle,
            mood: .idle
        )
    }

    // MARK: - Internals

    /// Truncate task for bubble; empty → nil.
    private static func softTask(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.count <= 48 { return t }
        return String(t.prefix(45)) + "…"
    }

    private static func softStatus(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Honest secondary line for failed/wary: task → outcome evidence → status → who.
    private static func nonWorkDetail(
        who: String,
        statusLine: String,
        task: String?,
        lastOutcome: String? = nil
    ) -> String? {
        if let task { return task }
        if let evidence = outcomeEvidence(lastOutcome) { return evidence }
        let s = statusLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        return who
    }

    /// Restate known outcome classes only (same sets as PetCodexMotion). Unknown → nil.
    private static func outcomeEvidence(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let o = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !o.isEmpty else { return nil }
        if Self.failedOutcomeLabels.contains(o) { return "Failed" }
        if Self.reviewOutcomeLabels.contains(o) { return "Task complete" }
        return nil
    }

    private static let failedOutcomeLabels: Set<String> = [
        "failed", "fail", "error", "errored", "failure", "crash", "crashed",
    ]
    private static let reviewOutcomeLabels: Set<String> = [
        "review", "done", "success", "succeeded", "completed", "complete", "passed",
    ]
}

// MARK: - Desktop companion selection (pure)

/// Which companion the floating desktop surface should show, plus bubble copy.
public struct DesktopCompanionPresentation: Sendable, Equatable {
    /// Primary companion, or nil when the roster is empty (procedural Shannon).
    public let state: CompanionState?
    public let bubble: CompanionBubbleContent
    /// Codex package pet id for atlas draw (default "shannon").
    public let packagePetId: String
    /// Procedural kind when state is nil or has no artwork.
    public let fallbackKind: CompanionKind

    public init(
        state: CompanionState?,
        bubble: CompanionBubbleContent,
        packagePetId: String = PetPackageResolver.defaultPetId,
        fallbackKind: CompanionKind = .owl
    ) {
        self.state = state
        self.bubble = bubble
        self.packagePetId = packagePetId
        self.fallbackKind = fallbackKind
    }

    public var mood: CompanionMood { state?.mood ?? bubble.mood }
    public var motion: PetCodexMotion { state?.codexMotion ?? bubble.motion }
    public var kind: CompanionKind? { state?.kind ?? fallbackKind }
}

public enum DesktopCompanionSelector {

    /// Pick the board-leading companion (working / waiting first) for the
    /// floating pet. Empty roster → watching bubble, no work claim.
    public static func present(
        roster: [CompanionState],
        packagePetId: String = PetPackageResolver.defaultPetId
    ) -> DesktopCompanionPresentation {
        guard let primary = roster.first else {
            return DesktopCompanionPresentation(
                state: nil,
                bubble: CompanionBubbleText.emptyRoster(),
                packagePetId: packagePetId,
                fallbackKind: .owl
            )
        }
        return DesktopCompanionPresentation(
            state: primary,
            bubble: CompanionBubbleText.derive(from: primary),
            packagePetId: packagePetId,
            fallbackKind: primary.kind ?? .owl
        )
    }

    /// Build from activity summary (same inputs as CompanionBoardView).
    public static func present(
        summary: AgentActivitySummary,
        now: Date = Date(),
        approvals: [String: Date] = [:],
        entropyDeltas: [String: Double] = [:],
        entropyDelta: Double? = nil,
        pendingAsks: [GateDBReader.PendingAsk] = [],
        lastOutcomes: [String: String] = [:],
        activity: [GateDBReader.ActivityEvent] = [],
        packagePetId: String = PetPackageResolver.defaultPetId
    ) -> DesktopCompanionPresentation {
        let roster = CompanionRoster.build(
            from: summary,
            now: now,
            approvals: approvals,
            entropyDeltas: entropyDeltas,
            entropyDelta: entropyDelta,
            pendingAsks: pendingAsks,
            lastOutcomes: lastOutcomes,
            activity: activity
        )
        return present(roster: roster, packagePetId: packagePetId)
    }
}
