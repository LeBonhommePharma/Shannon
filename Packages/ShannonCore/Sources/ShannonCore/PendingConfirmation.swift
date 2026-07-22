import Foundation

public enum ConfirmationAnswer: String, Codable, Sendable, Equatable {
    case confirmed
    case denied
}

/// How the answer was given. Recorded so the Mac's log shows whether LP
/// nodded, pinched, spoke, or tapped — useful when a gesture misfires.
public enum ConfirmationSource: String, Codable, Sendable, Equatable, CaseIterable {
    case tap
    case headNod
    case headShake
    case doubleTap
    case voice
    case stemPress
    case crown
}

/// A question the Mac agent is blocked on, mirrored to the phone and watch so
/// it can be answered away from the desk.
///
/// Question and detail are agent-authored text. They are stored in the
/// **private** CloudKit database only, never the public one.
public struct PendingConfirmation: CloudSyncable, Codable, Identifiable, Hashable {
    public var id: String
    public var question: String
    public var detail: String
    /// Agent that is blocked, for display alongside its card.
    public var agentID: String?
    public var createdAt: Date
    /// Answers arriving after this are ignored — a prompt LP never saw should
    /// not be answered by a stale gesture an hour later.
    public var expiresAt: Date

    public static let defaultLifetime: TimeInterval = 15 * 60

    public init(
        id: String = UUID().uuidString,
        question: String,
        detail: String = "",
        agentID: String? = nil,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.question = question
        self.detail = detail
        self.agentID = agentID
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Self.defaultLifetime)
    }

    public func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }

    // MARK: CloudSyncable

    public static let recordType = "PendingConfirmation"
    public var recordName: String { "confirmation-\(id)" }

    enum Field {
        static let id = "confirmationID"
        static let question = "question"
        static let detail = "detail"
        static let agentID = "agentID"
        static let createdAt = "createdAt"
        static let expiresAt = "expiresAt"
    }

    public var cloudFields: CloudFields {
        var f: CloudFields = [
            Field.id: .string(id),
            Field.question: .string(question),
            Field.detail: .string(detail),
            Field.createdAt: .date(createdAt),
            Field.expiresAt: .date(expiresAt),
            CloudKeys.updatedAt: .date(createdAt),
        ]
        if let agentID { f[Field.agentID] = .string(agentID) }
        return f
    }

    public init(cloudFields f: CloudFields) throws {
        self.init(
            id: try f.string(Field.id),
            question: try f.string(Field.question),
            detail: try f.string(Field.detail),
            agentID: try f.optionalString(Field.agentID),
            createdAt: try f.date(Field.createdAt),
            expiresAt: try f.date(Field.expiresAt)
        )
    }
}

/// The phone's or watch's answer, written back for the Mac to act on.
public struct ConfirmationResponse: CloudSyncable, Codable, Identifiable, Hashable {
    /// Same id as the prompt: one answer per question, and a double-fired
    /// gesture overwrites rather than queueing a second contradictory answer.
    public var id: String
    public var answer: ConfirmationAnswer
    public var source: ConfirmationSource
    /// Device that answered, e.g. "iPhone" — shown in the Mac's log.
    public var origin: String
    public var answeredAt: Date

    public init(
        id: String,
        answer: ConfirmationAnswer,
        source: ConfirmationSource,
        origin: String,
        answeredAt: Date = Date()
    ) {
        self.id = id
        self.answer = answer
        self.source = source
        self.origin = origin
        self.answeredAt = answeredAt
    }

    public init(
        confirmation: PendingConfirmation,
        answer: ConfirmationAnswer,
        source: ConfirmationSource,
        origin: String,
        answeredAt: Date = Date()
    ) {
        self.init(id: confirmation.id, answer: answer, source: source,
                  origin: origin, answeredAt: answeredAt)
    }

    // MARK: CloudSyncable

    public static let recordType = "ConfirmationResponse"
    public var recordName: String { "response-\(id)" }

    enum Field {
        static let id = "confirmationID"
        static let answer = "answer"
        static let source = "source"
        static let origin = "origin"
        static let answeredAt = "answeredAt"
    }

    public var cloudFields: CloudFields {
        [
            Field.id: .string(id),
            Field.answer: .string(answer.rawValue),
            Field.source: .string(source.rawValue),
            Field.origin: .string(origin),
            Field.answeredAt: .date(answeredAt),
            CloudKeys.updatedAt: .date(answeredAt),
        ]
    }

    public init(cloudFields f: CloudFields) throws {
        let rawAnswer = try f.string(Field.answer)
        guard let answer = ConfirmationAnswer(rawValue: rawAnswer) else {
            throw CloudDecodeError.unknownEnumValue(field: Field.answer, value: rawAnswer)
        }
        let rawSource = try f.string(Field.source)
        guard let source = ConfirmationSource(rawValue: rawSource) else {
            throw CloudDecodeError.unknownEnumValue(field: Field.source, value: rawSource)
        }
        self.init(
            id: try f.string(Field.id),
            answer: answer,
            source: source,
            origin: try f.string(Field.origin),
            answeredAt: try f.date(Field.answeredAt)
        )
    }
}
