import Foundation
#if canImport(CoreAudio)
import CoreAudio
#endif

/// Which head-worn Apple device is on the current output route, if any.
///
/// Derived from the CoreAudio device name because macOS exposes no model
/// identifier for Bluetooth audio devices. Name matching is imperfect — a user
/// can rename their AirPods — so `unknownBluetooth` is a first-class case
/// rather than a failure.
public enum AirPodsModel: String, Sendable, Equatable {
    case airPodsPro
    case airPodsMax
    case airPods
    case beats
    case unknownBluetooth

    /// SF Symbol for the pill indicator.
    public var symbolName: String {
        switch self {
        case .airPodsPro:      return "airpodspro"
        case .airPodsMax:      return "airpodsmax"
        case .airPods:         return "airpods"
        case .beats:           return "beats.headphones"
        case .unknownBluetooth: return "headphones"
        }
    }

    public var displayName: String {
        switch self {
        case .airPodsPro:      return "AirPods Pro"
        case .airPodsMax:      return "AirPods Max"
        case .airPods:         return "AirPods"
        case .beats:           return "Beats"
        case .unknownBluetooth: return "Bluetooth headphones"
        }
    }

    /// Classify from a CoreAudio device name. Order matters: "AirPods Pro"
    /// must be tested before the bare "AirPods" prefix.
    public static func from(deviceName: String) -> AirPodsModel? {
        let n = deviceName.lowercased()
        if n.contains("airpods max") { return .airPodsMax }
        if n.contains("airpods pro") { return .airPodsPro }
        if n.contains("airpods")     { return .airPods }
        if n.contains("beats") || n.contains("powerbeats") { return .beats }
        return nil
    }
}

public struct AudioOutputRoute: Sendable, Equatable {
    public let deviceName: String
    public let isBluetooth: Bool
    /// Nil when the route is not a recognised head-worn Apple/Beats device.
    public let model: AirPodsModel?

    public init(deviceName: String, isBluetooth: Bool) {
        self.deviceName = deviceName
        self.isBluetooth = isBluetooth
        // Only claim a model for a Bluetooth route: a wired interface named
        // "AirPods" is someone's oddly-named audio device, not AirPods.
        self.model = isBluetooth
            ? (AirPodsModel.from(deviceName: deviceName) ?? .unknownBluetooth)
            : AirPodsModel.from(deviceName: deviceName)
    }

    /// True when spoken output is going somewhere private.
    public var isHeadworn: Bool { model != nil }
}

/// What changed between two routes — drives hold/resume of spoken output.
public enum RouteTransition: Sendable, Equatable {
    case headwornConnected(AirPodsModel)
    case headwornDisconnected(AirPodsModel)
    case changedOutput(String)
    case none

    public static func between(old: AudioOutputRoute?, new: AudioOutputRoute?) -> RouteTransition {
        switch (old?.model, new?.model) {
        case let (nil, .some(m)):
            return .headwornConnected(m)
        case let (.some(m), nil):
            return .headwornDisconnected(m)
        case let (.some(a), .some(b)) where a != b:
            return .headwornConnected(b)
        default:
            if let o = old?.deviceName, let n = new?.deviceName, o != n {
                return .changedOutput(n)
            }
            return .none
        }
    }
}

/// Contract: `onChange` is always invoked on the main thread, and `start`
/// delivers the current route once before any subsequent changes. Both
/// implementations honour this so `Announcer` can update state synchronously.
public protocol AudioRouteProviding: AnyObject {
    var currentRoute: AudioOutputRoute? { get }
    func start(onChange: @escaping (AudioOutputRoute?) -> Void)
    func stop()
}

public final class StubAudioRouteProvider: AudioRouteProviding {
    public var currentRoute: AudioOutputRoute?
    private var handler: ((AudioOutputRoute?) -> Void)?
    public init(route: AudioOutputRoute? = nil) { currentRoute = route }

    public func start(onChange: @escaping (AudioOutputRoute?) -> Void) {
        handler = onChange
        onChange(currentRoute)
    }

    public func stop() { handler = nil }

    public func simulate(_ route: AudioOutputRoute?) {
        currentRoute = route
        handler?(route)
    }
}

#if canImport(CoreAudio)
/// Watches the system default output device.
///
/// macOS has no `AVAudioSession.routeChangeNotification` — that API is
/// `API_UNAVAILABLE(macos)`. The equivalent is a CoreAudio property listener on
/// `kAudioHardwarePropertyDefaultOutputDevice`.
///
/// Note what this can and cannot see: it detects AirPods **connecting and
/// disconnecting** as the default output. It does **not** detect in-ear versus
/// out-of-ear — macOS exposes no ear-detection API. Taking AirPods out usually
/// causes macOS to switch the default output away after a delay, which surfaces
/// here as a disconnect, but that is a side effect and not the same signal.
public final class CoreAudioRouteProvider: AudioRouteProviding {
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var handler: ((AudioOutputRoute?) -> Void)?

    public init() {}
    deinit { stop() }

    public var currentRoute: AudioOutputRoute? {
        guard let id = Self.defaultOutputDeviceID() else { return nil }
        guard let name = Self.stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioOutputRoute(deviceName: name, isBluetooth: Self.isBluetooth(id))
    }

    public func start(onChange: @escaping (AudioOutputRoute?) -> Void) {
        handler = onChange
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let route = self.currentRoute
            DispatchQueue.main.async { self.handler?(route) }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        onChange(currentRoute)
    }

    public func stop() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        listenerBlock = nil
        handler = nil
    }

    // MARK: CoreAudio plumbing

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? (value as String) : nil
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        guard status == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}
#endif
