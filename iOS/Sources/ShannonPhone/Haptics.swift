import Foundation
import ShannonCore
#if canImport(UIKit)
import UIKit
#endif

/// Thin wrapper so alert semantics, not raw feedback generators, appear in the
/// app code. Every entry point is a no-op on platforms without haptics.
enum Haptics {
    static func play(for alert: SnapshotAssembler.Alert) {
        switch alert {
        case .docking(.benchmarkFinished):
            notify(.success)
        case .docking(.targetCompleted):
            tap()
        case .agentErrored:
            notify(.error)
        case .agentFinished:
            notify(.success)
        case .notification:
            tap()
        }
    }

    #if canImport(UIKit)
    typealias NotificationStyle = UINotificationFeedbackGenerator.FeedbackType

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
    enum NotificationStyle { case success, warning, error }
    static func notify(_ style: NotificationStyle) {}
    static func tap() {}
    #endif
}
