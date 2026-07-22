import Foundation
import Observation
import AVFoundation
import Speech
import ShannonCore

/// Press-and-hold dictation, on-device only.
///
/// `requiresOnDeviceRecognition = true` is a privacy decision, not a
/// performance one: agent questions and LP's answers never leave the phone for
/// Apple's speech servers. If a device cannot do on-device recognition, the
/// mic button is hidden rather than silently falling back to the network.
@available(iOS 17.0, *)
@MainActor
@Observable
public final class VoiceDictation {
    public private(set) var isListening = false
    /// Live transcript, shown inline while LP is speaking.
    public private(set) var transcript = ""
    /// Recent audio levels, 0...1, driving the waveform under the mic button.
    public private(set) var levels: [Float] = Array(repeating: 0, count: 24)
    public private(set) var isAuthorized = false
    public private(set) var isAvailable = false
    /// Double-tap the mic to keep listening without holding.
    public var isHandsFree = false

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    public init() {
        isAvailable = recognizer?.supportsOnDeviceRecognition ?? false
    }

    /// Asks for both permissions up front — the mic button is only shown once
    /// they are granted, so LP never taps a control that cannot work.
    public func requestAuthorization() async {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        isAuthorized = (speech == .authorized) && mic
    }

    public func start() {
        guard isAuthorized, isAvailable, !isListening, let recognizer else { return }

        transcript = ""
        levels = Array(repeating: 0, count: levels.count)

        let session = AVAudioSession.sharedInstance()
        do {
            // Voice-chat mode engages voice isolation on AirPods, which is
            // what makes dictation usable with a benchmark fan running.
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.duckOthers, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.peakLevel(of: buffer)
            Task { @MainActor in self?.push(level: level) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanUp()
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.finishAudio()
                }
            }
        }
    }

    /// Stops listening and hands back the final transcript.
    public func stop(_ completion: @escaping (String?) -> Void) {
        guard isListening else {
            completion(nil)
            return
        }
        let finalTranscript = transcript
        request?.endAudio()
        finishAudio()
        completion(finalTranscript.isEmpty ? nil : finalTranscript)
    }

    /// Parsed command for the current transcript, so the UI can preview what
    /// releasing the mic will do.
    public var previewCommand: VoiceCommand? {
        transcript.isEmpty ? nil : VoiceCommand.parse(transcript)
    }

    private func finishAudio() {
        guard isListening else { return }
        isListening = false
        cleanUp()
    }

    private func cleanUp() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        levels = Array(repeating: 0, count: levels.count)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    /// Peak magnitude of a buffer, clamped to 0...1 for the waveform.
    nonisolated static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(channel[index]))
        }
        return min(peak * 2.2, 1)
    }
}
