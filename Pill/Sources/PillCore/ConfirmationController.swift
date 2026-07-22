import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum ConfirmationAnswer: String, Sendable, Equatable {
    case confirmed
    case denied
}

/// How an answer arrived — gestures and clicks are both first-class, so the
/// pill is never unusable without AirPods.
public enum ConfirmationSource: String, Sendable, Equatable {
    case gesture
    case click
}

public struct ConfirmationPrompt: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let question: String
    /// Context line, e.g. the ligand or branch being acted on.
    public let detail: String?

    public init(id: UUID = UUID(), question: String, detail: String? = nil) {
        self.id = id
        self.question = question
        self.detail = detail
    }
}

/// Brief colour wash confirming that a gesture registered.
public enum ConfirmationFlash: String, Sendable, Equatable {
    case confirm
    case deny
}

// MARK: - Feedback

public protocol ConfirmationFeedbackPerforming: AnyObject {
    func perform(_ answer: ConfirmationAnswer)
}

/// Records calls instead of making noise. Used by tests.
public final class RecordingFeedback: ConfirmationFeedbackPerforming {
    public private(set) var performed: [ConfirmationAnswer] = []
    public init() {}
    public func perform(_ answer: ConfirmationAnswer) { performed.append(answer) }
}

#if canImport(AppKit)
/// Haptic + sound cue.
///
/// `NSHapticFeedbackManager` only actually vibrates on a Force Touch trackpad;
/// on other hardware the call is a no-op, which is why a sound accompanies it
/// rather than replacing it.
public final class SystemConfirmationFeedback: ConfirmationFeedbackPerforming {
    public init() {}

    public func perform(_ answer: ConfirmationAnswer) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            answer == .confirmed ? .generic : .levelChange,
            performanceTime: .now
        )
        // Quiet, already-installed system sounds; no bundled assets.
        NSSound(named: answer == .confirmed ? "Tink" : "Funk")?.play()
    }
}
#endif

// MARK: - Controller

/// Owns the "awaiting confirmation" state and is the sole thing that arms the
/// gesture detector.
///
/// The gating is the safety property worth stating plainly: the detector is
/// armed in `ask` and disarmed the instant an answer is produced, so head
/// movement outside a prompt cannot answer anything. A prompt is answered at
/// most once — the second answer is dropped, whether it came from a gesture
/// racing a click or a double nod.
@MainActor
public final class ConfirmationController: ObservableObject {
    @Published public private(set) var prompt: ConfirmationPrompt?
    @Published public private(set) var flash: ConfirmationFlash?
    @Published public private(set) var gesturesAvailable: Bool

    /// Why gestures are unavailable, surfaced in the expanded pill.
    public var gestureStatus: String { provider.authorizationDescription }

    private var detector: HeadGestureDetector
    private let provider: HeadphoneMotionProviding
    private let feedback: ConfirmationFeedbackPerforming
    private var completion: ((ConfirmationAnswer, ConfirmationSource) -> Void)?
    private var flashTask: Task<Void, Never>?

    public init(
        provider: HeadphoneMotionProviding,
        feedback: ConfirmationFeedbackPerforming,
        config: HeadGestureConfig = .default
    ) {
        self.provider = provider
        self.feedback = feedback
        self.detector = HeadGestureDetector(config: config)
        self.gesturesAvailable = provider.isAvailable
    }

    public var isAwaitingConfirmation: Bool { prompt != nil }

    /// Present a question and arm gestures until it is answered.
    public func ask(
        _ prompt: ConfirmationPrompt,
        onAnswer: @escaping (ConfirmationAnswer, ConfirmationSource) -> Void
    ) {
        // A new question supersedes an unanswered one.
        cancel()
        self.prompt = prompt
        self.completion = onAnswer

        gesturesAvailable = provider.isAvailable
        guard gesturesAvailable else { return }

        detector.arm()
        provider.start { [weak self] sample in
            Task { @MainActor in self?.handle(sample) }
        }
    }

    /// Answer from the UI.
    public func answer(_ answer: ConfirmationAnswer) {
        resolve(answer, source: .click)
    }

    /// Withdraw the prompt without answering.
    public func cancel() {
        teardown()
        prompt = nil
        completion = nil
    }

    private func handle(_ sample: HeadAttitudeSample) {
        guard prompt != nil else { return }
        guard let gesture = detector.process(sample) else { return }
        resolve(gesture == .nod ? .confirmed : .denied, source: .gesture)
    }

    private func resolve(_ answer: ConfirmationAnswer, source: ConfirmationSource) {
        // Drop the loser of a gesture/click race rather than answering twice.
        guard prompt != nil, let completion else { return }
        teardown()
        self.prompt = nil
        self.completion = nil

        feedback.perform(answer)
        showFlash(answer == .confirmed ? .confirm : .deny)
        completion(answer, source)
    }

    private func teardown() {
        detector.disarm()
        provider.stop()
    }

    private func showFlash(_ kind: ConfirmationFlash) {
        flash = kind
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }
}
