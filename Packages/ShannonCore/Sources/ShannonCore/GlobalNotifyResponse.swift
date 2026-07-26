import Foundation

// MARK: - OS-agnostic notification + response contract

/// Pure helpers for the global notify/respond system shared by Mac, iPhone,
/// iPad, and Watch. Platforms only adapt presentation and local feedback
/// (haptics, crown, stem); they must not invent prompts or second queues.
///
/// Contract:
/// - One logical pending item = one `PendingConfirmation.id`
/// - Answers carry `ConfirmationAnswer` + `ConfirmationSource` + origin
/// - Expired prompts reject answers (fail-closed)
/// - Optional agent/detail stay nil when omitted
/// - Edge-triggered “needs attention” haptics fire only on new ids / transitions
public enum GlobalNotifyResponse {

    // MARK: Pending identity

    /// Stable multi-surface identity for a pending decision.
    public static func identity(of pending: PendingConfirmation) -> String {
        pending.id
    }

    /// Active (non-expired) pending items, oldest first — same order on every OS.
    public static func activePending(
        in snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> [PendingConfirmation] {
        snapshot.confirmations
            .filter { !$0.isExpired(now: now) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Primary pending decision (oldest non-expired), or nil.
    public static func primaryPending(
        in snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> PendingConfirmation? {
        activePending(in: snapshot, now: now).first
    }

    /// Multi-consumer agreement: same snapshot content → same primary id + question.
    public static func consumersAgreeOnPending(
        _ snapshots: [ShannonSnapshot],
        now: Date = Date()
    ) -> Bool {
        guard snapshots.count >= 2 else { return true }
        let primaries = snapshots.map { primaryPending(in: $0, now: now) }
        let first = primaries[0]
        for other in primaries.dropFirst() {
            switch (first, other) {
            case (nil, nil):
                continue
            case let (a?, b?):
                if a.id != b.id { return false }
                if a.question != b.question { return false }
                if a.agentID != b.agentID { return false }
            default:
                return false
            }
        }
        return true
    }

    // MARK: Answer policy (fail-closed)

    /// Whether this prompt may still be answered.
    public static func canAnswer(
        _ pending: PendingConfirmation,
        now: Date = Date()
    ) -> Bool {
        !pending.isExpired(now: now) && !pending.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Build a response or return nil if the prompt is expired / empty.
    /// Never invents question text or agent id.
    public static func makeResponse(
        for pending: PendingConfirmation,
        answer: ConfirmationAnswer,
        source: ConfirmationSource,
        origin: String,
        now: Date = Date()
    ) -> ConfirmationResponse? {
        guard canAnswer(pending, now: now) else { return nil }
        let originTrim = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originTrim.isEmpty else { return nil }
        return ConfirmationResponse(
            confirmation: pending,
            answer: answer,
            source: source,
            origin: originTrim,
            answeredAt: now
        )
    }

    // MARK: Gesture / voice → answer mapping (hardware-free)

    /// Head gesture → answer + source (shared Mac/iPhone mapping).
    public static func mapHeadGesture(_ gesture: HeadGesture) -> (ConfirmationAnswer, ConfirmationSource) {
        switch gesture {
        case .nod: return (.confirmed, .headNod)
        case .shake: return (.denied, .headShake)
        }
    }

    /// Voice command → answer + source when the command is confirm/deny.
    public static func mapVoice(_ command: VoiceCommand) -> (ConfirmationAnswer, ConfirmationSource)? {
        guard let answer = command.confirmationAnswer else { return nil }
        return (answer, .voice)
    }

    /// Tap / crown / stem convenience mappings.
    public static func mapTap(approved: Bool) -> (ConfirmationAnswer, ConfirmationSource) {
        (approved ? .confirmed : .denied, .tap)
    }

    public static func mapCrown(approved: Bool) -> (ConfirmationAnswer, ConfirmationSource) {
        (approved ? .confirmed : .denied, .crown)
    }

    public static func mapStem(approved: Bool) -> (ConfirmationAnswer, ConfirmationSource) {
        (approved ? .confirmed : .denied, .stemPress)
    }

    public static func mapDoubleTap(approved: Bool) -> (ConfirmationAnswer, ConfirmationSource) {
        (approved ? .confirmed : .denied, .doubleTap)
    }

    // MARK: User-facing notification content (pure strings)

    public struct NotifyContent: Sendable, Equatable {
        public var title: String
        public var body: String
        public var confirmationID: String?
        public var agentID: String?

        public init(title: String, body: String, confirmationID: String? = nil, agentID: String? = nil) {
            self.title = title
            self.body = body
            self.confirmationID = confirmationID
            self.agentID = agentID
        }
    }

    /// Content for a pending confirmation — same wording family on every OS.
    public static func content(for pending: PendingConfirmation) -> NotifyContent {
        let agent = pending.agentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = pending.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let agent, !agent.isEmpty {
            title = "\(agent) needs you"
        } else {
            title = "Approval needed"
        }
        let body = q.isEmpty ? "An agent is waiting for your answer" : q
        return NotifyContent(
            title: title,
            body: body,
            confirmationID: pending.id,
            agentID: (agent?.isEmpty == false) ? agent : nil
        )
    }

    /// Focus line for HUD / menu / complication when a decision is open.
    public static func needsYouFocusLine(
        in snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> String? {
        guard let p = primaryPending(in: snapshot, now: now) else { return nil }
        let c = content(for: p)
        if let agent = c.agentID {
            return "Needs you · \(agent)"
        }
        return "Needs you"
    }
}

// MARK: - Edge-triggered attention (haptic) policy

/// Pure edge tracker: fires once per confirmation id (and once per new
/// notification / agent transition via `SnapshotAssembler`). Use this when a
/// surface needs only confirmation edges without the full assembler.
public struct ConfirmationAlertEdge: Sendable, Equatable {
    private var seenIDs: Set<String>

    public init(seenIDs: Set<String> = []) {
        self.seenIDs = seenIDs
    }

    /// New non-expired confirmations not seen before → edge events, oldest first.
    public mutating func edges(
        from snapshot: ShannonSnapshot,
        now: Date = Date()
    ) -> [PendingConfirmation] {
        var out: [PendingConfirmation] = []
        for pending in GlobalNotifyResponse.activePending(in: snapshot, now: now) {
            guard !seenIDs.contains(pending.id) else { continue }
            seenIDs.insert(pending.id)
            out.append(pending)
        }
        return out
    }

    /// Identical re-feed of the same pending set produces no edges.
    public mutating func hasEdge(onRepeated snapshot: ShannonSnapshot, now: Date = Date()) -> Bool {
        !edges(from: snapshot, now: now).isEmpty
    }
}

// MARK: - Multi-surface pending view (shared binding)

/// Frozen view of one pending decision for multi-OS identity tests.
public struct GlobalPendingView: Sendable, Equatable, Identifiable {
    public var id: String
    public var question: String
    public var agentID: String?
    public var isAnswerable: Bool
    public var focusLine: String

    public init(id: String, question: String, agentID: String?, isAnswerable: Bool, focusLine: String) {
        self.id = id
        self.question = question
        self.agentID = agentID
        self.isAnswerable = isAnswerable
        self.focusLine = focusLine
    }

    public static func from(
        _ pending: PendingConfirmation,
        now: Date = Date()
    ) -> GlobalPendingView {
        let answerable = GlobalNotifyResponse.canAnswer(pending, now: now)
        let content = GlobalNotifyResponse.content(for: pending)
        let focus: String
        if let agent = content.agentID {
            focus = "Needs you · \(agent)"
        } else {
            focus = "Needs you"
        }
        return GlobalPendingView(
            id: pending.id,
            question: pending.question,
            agentID: pending.agentID,
            isAnswerable: answerable,
            focusLine: focus
        )
    }
}
