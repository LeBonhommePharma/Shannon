import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Notification kinds the pill posts for approvals and measured collapses.
public enum ShannonNotificationKind: String, Sendable, Equatable {
    case ask
    case collapse
}

/// Title/body pairs for local notifications — pure strings, no posting.
public struct ShannonNotificationContent: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Builds and (optionally) posts local notifications for gate events.
///
/// Content generation is pure and unit-tested without posting. Delivery uses
/// `UNUserNotificationCenter` when the framework is available.
public enum ShannonNotifier {
    /// Pure title/body for a notification kind. Callers may override with
    /// concrete prompt text or H values.
    public static func notificationContent(
        kind: ShannonNotificationKind,
        title: String? = nil,
        body: String? = nil
    ) -> ShannonNotificationContent {
        switch kind {
        case .ask:
            return ShannonNotificationContent(
                title: title ?? "Approval needed",
                body: body ?? "An agent is waiting for your answer"
            )
        case .collapse:
            return ShannonNotificationContent(
                title: title ?? "Entropy collapse",
                body: body ?? "Measured token entropy collapsed"
            )
        }
    }

    /// Request alert permission (best-effort; no-op without UserNotifications).
    public static func requestPermission() {
        #if canImport(UserNotifications)
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// True only in a real app host — xctest's mainBundle has no UN proxy.
    public static var canUseUserNotifications: Bool {
        #if canImport(UserNotifications)
        if ProcessInfo.processInfo.environment["SHANNON_FORCE_NOTIFY"] == "1" {
            return true
        }
        let mainPath = Bundle.main.bundleURL.path
        if mainPath.contains("xctest") || mainPath.contains("Xcode") {
            return false
        }
        if Bundle.main.bundleURL.pathExtension == "app" { return true }
        if Bundle.main.bundleIdentifier?.lowercased().contains("shannon") == true {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// Post when a new gate ask appears.
    public static func notifyAsk(prompt: String, agentId: String = "") {
        let agent = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if agent.isEmpty {
            body = prompt.isEmpty ? "An agent is waiting for your answer" : prompt
        } else if prompt.isEmpty {
            body = "\(agent) needs approval"
        } else {
            body = "\(agent): \(prompt)"
        }
        let content = notificationContent(kind: .ask, body: body)
        post(identifier: "shannon.ask.\(UUID().uuidString)", content: content)
    }

    /// Post when a measured bridge reading collapses.
    public static func notifyCollapse(bits: Double? = nil, source: String = "bridge") {
        let body: String
        if let bits {
            body = String(format: "H %.1f collapsed (%@)", bits, source)
        } else {
            body = "Measured token entropy collapsed (\(source))"
        }
        let content = notificationContent(kind: .collapse, body: body)
        post(identifier: "shannon.collapse.\(UUID().uuidString)", content: content)
    }

    // MARK: - Delivery

    private static func post(identifier: String, content: ShannonNotificationContent) {
        #if canImport(UserNotifications)
        // XCTest / bare xctest host has no app bundle proxy — calling
        // UNUserNotificationCenter.current() traps with NSInternalInconsistencyException.
        // Skip delivery outside a real app process; pure content builders still unit-test.
        guard canUseUserNotifications else { return }
        let un = UNMutableNotificationContent()
        un.title = content.title
        un.body = content.body
        un.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier,
            content: un,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        #endif
    }
}
