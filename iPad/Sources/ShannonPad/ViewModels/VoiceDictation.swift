import Foundation
import SwiftUI
import ShannonCore
#if canImport(Speech)
import AVFoundation
import Speech
#endif

/// The spoken vocabulary lives in `ShannonCore.VoiceCommand` so a phrase means
/// the same thing on the Mac, the Watch, the phone and here. This file only
/// turns audio into text and hands the text to that parser.

/// On-device dictation for the mic button in the navigation bar.
///
/// `requiresOnDeviceRecognition` is not a preference here — agent transcripts
/// name internal targets and file paths, and none of that is allowed to leave
/// the device for a speech server. When on-device recognition is unavailable
/// the controller reports that and stays silent rather than falling back.
@MainActor
final class VoiceDictationController: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    @Published private(set) var errorMessage: String?

    /// Fired once per recognised phrase, after a short settle.
    var onCommand: ((VoiceCommand) -> Void)?

    #if canImport(Speech)
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var settleTimer: Timer?
    #endif

    func toggle() {
        isListening ? stop() : start()
    }

    #if canImport(Speech)
    func start() {
        guard !isListening else { return }
        errorMessage = nil
        transcript = ""

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.errorMessage = "Speech recognition is not authorised."
                    return
                }
                self.beginSession()
            }
        }
    }

    private func beginSession() {
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recogniser unavailable."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            errorMessage = "On-device dictation unavailable on this iPad."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
                buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            errorMessage = "Could not start the microphone."
            teardown()
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.scheduleSettle()
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    /// Commands fire after a beat of silence rather than on every partial, so
    /// "show 1G9V" is not dispatched as "show one" mid-phrase.
    private func scheduleSettle() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.onCommand?(VoiceCommand.parse(self.transcript))
                self.stop()
            }
        }
    }

    func stop() {
        settleTimer?.invalidate()
        settleTimer = nil
        guard isListening else { teardown(); return }
        isListening = false
        teardown()
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    #else
    func start() { errorMessage = "Dictation unavailable on this platform." }
    func stop() { isListening = false }
    #endif
}
