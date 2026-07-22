import Foundation
import Observation
import AVFoundation
import MediaPlayer

/// AirPods Pro / Max integration: presence, in-ear detection, stem presses and
/// spoken announcements.
///
/// Audio policy throughout: Shannon never interrupts. Every announcement is
/// suppressed when other audio is playing or a call is active, and the session
/// uses `.spokenAudio` with `.duckOthers` so Conversation Awareness on
/// AirPods Pro 3 can pause Shannon the moment LP starts speaking.
@available(iOS 17.0, *)
@MainActor
@Observable
public final class AirPodsMonitor {
    public enum RemoteCommand: Sendable {
        case primary    // single stem press
        case secondary  // double press
        case tertiary   // triple press
    }

    public enum Kind: String, Sendable {
        case airPods
        case airPodsPro
        case airPodsMax
        case otherHeadphones
        case none

        /// SF Symbol for the navigation bar indicator.
        public var symbol: String {
            switch self {
            case .airPods:          return "airpods"
            case .airPodsPro:       return "airpodspro"
            case .airPodsMax:       return "airpodsmax"
            case .otherHeadphones:  return "headphones"
            case .none:             return "headphones"
            }
        }
    }

    public private(set) var kind: Kind = .none
    public private(set) var isConnected = false
    /// Nil when the level is unknown — never guess a battery number.
    public private(set) var batteryPercent: Int?
    public private(set) var isSpeaking = false

    /// Shown only at or below this level; above it the indicator is noise.
    public static let lowBatteryThreshold = 30

    public var showsLowBattery: Bool {
        guard let batteryPercent else { return false }
        return batteryPercent <= Self.lowBatteryThreshold
    }

    @ObservationIgnored public var onRemoteCommand: ((RemoteCommand) -> Void)?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init() {}

    public func start() {
        configureSession()
        refreshRoute()
        registerRouteObserver()
        registerRemoteCommands()
    }

    public func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: Session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.spokenAudio` is the mode Apple routes through Conversation
            // Awareness; `.duckOthers` means a podcast dips rather than stops.
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.duckOthers, .allowBluetoothA2DP])
        } catch {
            // Audio output is a convenience here — the app is fully usable
            // without it, so a failed session must not surface as an error.
        }
    }

    private func registerRouteObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                // Old device unavailable == AirPods pulled out of the ear.
                // Cut any in-flight announcement rather than blaring it out
                // of the phone speaker.
                if reason == .oldDeviceUnavailable {
                    self.synthesizer.stopSpeaking(at: .immediate)
                    self.isSpeaking = false
                }
                self.refreshRoute()
            }
        }
        observers.append(observer)
    }

    private func refreshRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let output = outputs.first(where: {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP
                || $0.portType == .headphones
        }) else {
            isConnected = false
            kind = .none
            batteryPercent = nil
            return
        }

        isConnected = true
        let name = output.portName.lowercased()
        if name.contains("max") {
            kind = .airPodsMax
        } else if name.contains("pro") {
            kind = .airPodsPro
        } else if name.contains("airpods") {
            kind = .airPods
        } else {
            kind = .otherHeadphones
        }
    }

    /// Battery level for the connected accessory.
    ///
    /// iOS exposes no public API for AirPods battery — the Bluetooth battery
    /// service is not readable by third-party apps for Apple-designed
    /// accessories, and CoreBluetooth cannot see an already-paired HFP device.
    /// Rather than display a fabricated number, the indicator stays hidden
    /// unless a level is supplied by a source that genuinely knows it.
    public func setBatteryPercent(_ percent: Int?) {
        batteryPercent = percent.map { min(max($0, 0), 100) }
    }

    // MARK: Stem presses

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onRemoteCommand?(.primary) }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onRemoteCommand?(.primary) }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onRemoteCommand?(.primary) }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onRemoteCommand?(.secondary) }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onRemoteCommand?(.tertiary) }
            return .success
        }
    }

    // MARK: Speech

    /// Speaks a short line, unless doing so would talk over something.
    public func announce(_ text: String) {
        guard !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()

        // Never interrupt a call or another app's audio.
        guard !session.isOtherAudioPlaying else { return }
        guard session.category != .playAndRecord else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1
        isSpeaking = true
        synthesizer.speak(utterance)

        // AVSpeechSynthesizer's delegate is the accurate signal; this is a
        // conservative fallback so the flag cannot stick on.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(text.count) / 12 + 1))
            self?.isSpeaking = false
        }
    }
}
