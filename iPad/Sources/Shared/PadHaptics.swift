import Foundation
import ShannonCore
#if canImport(UIKit)
import UIKit
#endif

/// Alert semantics rather than raw feedback generators, matching the phone's
/// `Haptics`. iPads without a Taptic Engine simply get nothing back, so every
/// entry point has to be safe to call unconditionally.
enum PadHaptics {
    #if canImport(UIKit)
    typealias NotificationStyle = UINotificationFeedbackGenerator.FeedbackType
    #else
    enum NotificationStyle { case success, warning, error }
    #endif

    static func play(for alert: SnapshotAssembler.Alert) {
        switch alert {
        case .docking(.benchmarkFinished): notify(.success)
        case .docking(.targetCompleted):   tap()
        case .agentErrored:                notify(.error)
        case .agentFinished:               notify(.success)
        case .notification:                tap()
        @unknown default:                  tap()
        }
    }

    #if canImport(UIKit)
    static func notify(_ style: NotificationStyle) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(style)
    }

    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
    #else
    static func notify(_ style: NotificationStyle) {}
    static func tap() {}
    #endif
}
