import Foundation
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFAudio)
import AVFAudio
#endif

public enum DictationState: Sendable, Equatable {
    case idle
    case listening(partial: String)
    case finished(String)
    case failed(String)

    public var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    public var transcript: String {
        switch self {
        case .idle: return ""
        case .listening(let p): return p
        case .finished(let t): return t
        case .failed: return ""
        }
    }
}

public enum DictationAuthorization: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable   // no recognizer for this locale, or on-device unsupported
}

public protocol DictationProviding: AnyObject {
    var authorization: DictationAuthorization { get }
    /// True when on-device recognition is possible. Shannon refuses to fall
    /// back to server recognition, so this being false disables dictation.
    var supportsOnDevice: Bool { get }
    func requestAuthorization(_ completion: @escaping (DictationAuthorization) -> Void)
    func start(onUpdate: @escaping (DictationState) -> Void)
    func stop()
}

/// Deterministic dictation source for tests and `--demo`.
public final class StubDictationProvider: DictationProviding {
    public var authorization: DictationAuthorization = .authorized
    public var supportsOnDevice: Bool = true
    public private(set) var isRunning = false
    private var handler: ((DictationState) -> Void)?

    public init() {}

    public func requestAuthorization(_ completion: @escaping (DictationAuthorization) -> Void) {
        completion(authorization)
    }

    public func start(onUpdate: @escaping (DictationState) -> Void) {
        handler = onUpdate
        isRunning = true
        onUpdate(.listening(partial: ""))
    }

    public func stop() {
        isRunning = false
        handler = nil
    }

    public func emit(_ state: DictationState) { handler?(state) }
}

#if canImport(Speech)
/// On-device dictation via `SFSpeechRecognizer` + `AVAudioEngine`.
///
/// `requiresOnDeviceRecognition` is set unconditionally and never relaxed: if
/// the locale has no on-device model, dictation reports unavailable rather than
/// quietly shipping audio to Apple's servers. `SFSpeechRecognizer` is
/// `API_AVAILABLE(macos(10.15))` and the on-device flag `macos(10.15)`, so both
/// clear the pill's macOS 13 floor.
@available(macOS 13.0, *)
public final class SpeechDictationProvider: DictationProviding {
    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    deinit { stop() }

    public var authorization: DictationAuthorization {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .authorized:    return recognizer?.isAvailable == true ? .authorized : .unavailable
        @unknown default:    return .unavailable
        }
    }

    public var supportsOnDevice: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    public func requestAuthorization(_ completion: @escaping (DictationAuthorization) -> Void) {
        SFSpeechRecognizer.requestAuthorization { _ in
            DispatchQueue.main.async { completion(self.authorization) }
        }
    }

    public func start(onUpdate: @escaping (DictationState) -> Void) {
        guard authorization == .authorized, let recognizer else {
            onUpdate(.failed("speech recognition not authorized"))
            return
        }
        guard supportsOnDevice else {
            // Refusing here is the privacy promise: no server fallback.
            onUpdate(.failed("on-device recognition unavailable for this language"))
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanup()
            onUpdate(.failed("could not start audio engine: \(error.localizedDescription)"))
            return
        }

        onUpdate(.listening(partial: ""))
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.cleanup()
                    onUpdate(.finished(text))
                } else {
                    onUpdate(.listening(partial: text))
                }
            } else if let error {
                self.cleanup()
                onUpdate(.failed(error.localizedDescription))
            }
        }
    }

    public func stop() {
        // Ending audio lets the recognizer emit its final result.
        request?.endAudio()
        cleanup()
    }

    private func cleanup() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
    }
}
#endif
