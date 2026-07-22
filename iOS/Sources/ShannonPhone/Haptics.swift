import Foundation
import ShannonCore
import UIKit

/// Thin wrapper so alert semantics, not raw feedback generators, appear in the
/// app code. Haptics fire on every meaningful state change and nowhere else —
/// feedback that fires for routine refreshes stops meaning anything.
@MainActor
enum Haptics {
    /// Generators are kept alive and pre-warmed: allocating one at the moment
    /// of the tap costs tens of milliseconds and reads as lag.
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notifier = UINotificationFeedbackGenerator()

    static func prepare() {
        impactLight.prepare()
        impactMedium.prepare()
        impactRigid.prepare()
        notifier.prepare()
    }

    /// Light tap for view transitions and taps.
    static func transition() {
        impactLight.impactOccurred()
        impactLight.prepare()
    }

    /// Confirm and deny feel deliberately different, so LP knows which one
    /// landed without looking at the screen.
    static func confirmation(_ answer: ConfirmationAnswer) {
        switch answer {
        case .confirmed:
            impactMedium.impactOccurred()
            impactMedium.prepare()
        case .denied:
            impactRigid.impactOccurred()
            impactRigid.prepare()
        }
    }

    static func play(for alert: SnapshotAssembler.Alert) {
        switch alert {
        case .confirmationRequested:
            // The one alert that needs LP to act: strongest signal available.
            notifier.notificationOccurred(.warning)
        case .docking(.benchmarkFinished), .agentFinished:
            notifier.notificationOccurred(.success)
        case .agentErrored:
            notifier.notificationOccurred(.error)
        case .docking(.targetCompleted), .notification:
            transition()
        }
        notifier.prepare()
    }
}
