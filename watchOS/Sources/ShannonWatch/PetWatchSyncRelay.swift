import Foundation
import WatchConnectivity
import WidgetKit
import ShannonCore

// MARK: - PetWatchSyncRelay  (watch side)
//
// Truth lives on the iPhone. The watch receives `PetStateUpdate` via
// WatchConnectivity `applicationContext` and writes it to App Group defaults
// (so the complication can reload). Interaction events travel the other way:
// watch → phone via `sendMessage`.

@available(watchOS 10.0, *)
@MainActor
public final class PetWatchSyncRelay: NSObject {
    public static let shared = PetWatchSyncRelay()
    private let suite = "group.com.lebonhommepharma.shannon"
    private override init() { super.init() }

    public func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = _Delegate(relay: self)
        WCSession.default.activate()
    }

    public func sendInteraction(_ kind: PetInteractionKind) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["petInteraction": kind.rawValue],
                                      replyHandler: nil)
    }

    // Called from the WCSessionDelegate (below) on the delegate queue.
    fileprivate func didReceiveContext(_ ctx: [String: Any]) {
        guard let pet = ctx["pet"] as? [String: Any] else { return }
        let d = UserDefaults(suiteName: suite)
        d?.set(pet["mood"]       as? String, forKey: "pet.mood")
        d?.set(pet["level"]      as? Int,    forKey: "pet.level")
        d?.set(pet["name"]       as? String, forKey: "pet.name")
        d?.set(pet["avatarSeed"] as? String, forKey: "pet.avatarSeed")
        d?.set(pet["lastMemory"] as? String, forKey: "pet.lastMemory")
        WidgetCenter.shared.reloadTimelines(ofKind: "ShannonPetComplication")
    }
}

// MARK: - Private WCSessionDelegate (avoids polluting PetWatchSyncRelay's public API)

@available(watchOS 10.0, *)
private final class _Delegate: NSObject, WCSessionDelegate {
    weak var relay: PetWatchSyncRelay?
    init(relay: PetWatchSyncRelay) { self.relay = relay }

    func session(_ session: WCSession,
                 didReceiveApplicationContext ctx: [String: Any]) {
        Task { @MainActor in relay?.didReceiveContext(ctx) }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {}
}

// MARK: - PetPhoneSyncRelay  (phone side — kept in the same file for discoverability)
// Gated on #if os(iOS) because sessionDidBecomeInactive / sessionDidDeactivate
// are iOS-only WCSessionDelegate methods; @available alone does not suppress
// compilation on watchOS and the compiler rejects those overrides.

#if os(iOS)
@available(iOS 17.0, *)
@MainActor
public final class PetPhoneSyncRelay: NSObject {
    public static let shared = PetPhoneSyncRelay()
    private let store: PetStore
    private override init() { store = .shared }

    public func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = _PhoneDelegate(relay: self)
        WCSession.default.activate()
    }

    /// Push the current pet state to the watch. Call after any state change.
    public func pushToWatch(lastMemory: String = "") {
        guard WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled else { return }
        let ctx: [String: Any] = ["pet": [
            "mood":       store.pet.mood.rawValue,
            "level":      store.pet.level,
            "name":       store.pet.name,
            "avatarSeed": String(store.pet.avatarSeed),
            "lastMemory": lastMemory,
        ]]
        try? WCSession.default.updateApplicationContext(ctx)
    }

    fileprivate func didReceiveInteraction(raw: String) {
        guard let kind = PetInteractionKind(rawValue: raw) else { return }
        let engine = PetInteractionEngine(store: store,
                                          memory: PetMemoryStore(petID: store.pet.id))
        engine.handle(kind)
        pushToWatch()
    }
}

@available(iOS 17.0, *)
private final class _PhoneDelegate: NSObject, WCSessionDelegate {
    weak var relay: PetPhoneSyncRelay?
    init(relay: PetPhoneSyncRelay) { self.relay = relay }

    func session(_ session: WCSession, didReceiveMessage msg: [String: Any]) {
        guard let raw = msg["petInteraction"] as? String else { return }
        Task { @MainActor in relay?.didReceiveInteraction(raw: raw) }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
#endif // os(iOS)
