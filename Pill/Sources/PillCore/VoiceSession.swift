import Foundation

/// Actions a voice command can dispatch. The host app supplies the handlers;
/// `VoiceSession` never performs them itself, which keeps the routing testable.
public struct VoiceActions: Sendable {
    public var confirm: @Sendable () -> Void
    public var deny: @Sendable () -> Void
    public var showStatus: @Sendable () -> Void
    public var pause: @Sendable () -> Void
    public var runBenchmark: @Sendable () -> Void
    public var whatsDocking: @Sendable () -> Void
    public var query: @Sendable (String) -> Void

    public init(
        confirm: @escaping @Sendable () -> Void = {},
        deny: @escaping @Sendable () -> Void = {},
        showStatus: @escaping @Sendable () -> Void = {},
        pause: @escaping @Sendable () -> Void = {},
        runBenchmark: @escaping @Sendable () -> Void = {},
        whatsDocking: @escaping @Sendable () -> Void = {},
        query: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.confirm = confirm
        self.deny = deny
        self.showStatus = showStatus
        self.pause = pause
        self.runBenchmark = runBenchmark
        self.whatsDocking = whatsDocking
        self.query = query
    }
}

/// Drives a dictation session and dispatches the resulting command.
///
/// One deliberate restriction: `confirm` and `deny` are only dispatched when a
/// confirmation prompt is actually pending. Saying "yes" at an idle pill sends
/// a query to the agent instead of silently approving whatever ran last — the
/// same gating principle as the head-gesture detector.
@MainActor
public final class VoiceSession: ObservableObject {
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var lastCommand: VoiceCommand?
    @Published public private(set) var authorization: DictationAuthorization

    private let provider: DictationProviding
    private let parser = VoiceCommandParser()
    private var actions: VoiceActions

    /// Supplied by the host so the session knows whether confirm/deny are live.
    public var isConfirmationPending: () -> Bool = { false }

    public init(provider: DictationProviding, actions: VoiceActions = VoiceActions()) {
        self.provider = provider
        self.actions = actions
        self.authorization = provider.authorization
    }

    public var isListening: Bool { state.isListening }

    /// True only when dictation can run fully on-device.
    public var isAvailable: Bool {
        provider.authorization != .denied
            && provider.authorization != .restricted
            && provider.supportsOnDevice
    }

    public func toggle() {
        isListening ? cancel() : start()
    }

    public func start() {
        guard !isListening else { return }
        guard provider.supportsOnDevice else {
            state = .failed("on-device recognition unavailable for this language")
            return
        }

        if provider.authorization == .notDetermined {
            provider.requestAuthorization { [weak self] status in
                guard let self else { return }
                self.authorization = status
                if status == .authorized { self.beginListening() }
                else { self.state = .failed("speech recognition not authorized") }
            }
            return
        }

        guard provider.authorization == .authorized else {
            state = .failed("speech recognition not authorized")
            return
        }
        beginListening()
    }

    /// Abandon without dispatching — Escape, or a second double-tap.
    public func cancel() {
        provider.stop()
        state = .idle
    }

    private func beginListening() {
        provider.start { [weak self] newState in
            MainActor.assumeIsolated { self?.handle(newState) }
        }
    }

    private func handle(_ newState: DictationState) {
        state = newState
        guard case .finished(let transcript) = newState else { return }
        provider.stop()
        dispatch(transcript)
    }

    private func dispatch(_ transcript: String) {
        guard let command = parser.parse(transcript) else {
            state = .idle
            return
        }
        lastCommand = command

        switch command {
        case .confirm:
            // Only meaningful against a live prompt.
            isConfirmationPending() ? actions.confirm() : actions.query(transcript)
        case .deny:
            isConfirmationPending() ? actions.deny() : actions.query(transcript)
        case .showStatus:   actions.showStatus()
        case .pause:        actions.pause()
        case .runBenchmark: actions.runBenchmark()
        case .whatsDocking: actions.whatsDocking()
        case .query(let q): actions.query(q)
        }
    }
}
