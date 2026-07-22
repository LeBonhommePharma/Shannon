import Foundation
import UserNotifications
import ShannonCore

#if canImport(UIKit)
import UIKit
import SwiftUI

// MARK: - PetNotificationAvatar

/// Renders a snapshot of the pet's current mood face and attaches it to
/// outgoing `UNNotificationContent` so the banner shows the pet's avatar.
@available(iOS 17.0, *)
@MainActor
public enum PetNotificationAvatar {

    /// Render the avatar for the given seed + mood and return a
    /// `UNNotificationAttachment` that points to a temporary PNG file.
    public static func makeAttachment(
        seed: UInt64,
        mood: PetMood,
        size: CGFloat = 64
    ) -> UNNotificationAttachment? {
        let params   = PetAvatarDescriptor.params(for: seed)
        let renderer = ImageRenderer(
            content: PetAvatarCanvas(params: params, mood: mood, size: size)
        )
        renderer.scale = 3
        guard let image = renderer.uiImage,
              let png   = image.pngData() else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-\(seed)-\(mood.rawValue).png")
        try? png.write(to: url)
        return try? UNNotificationAttachment(identifier: "pet-avatar", url: url)
    }

    /// Convenience: attach the pet face to a mutable notification content object.
    public static func attach(
        to content: UNMutableNotificationContent,
        seed: UInt64,
        mood: PetMood
    ) {
        if let att = makeAttachment(seed: seed, mood: mood) {
            content.attachments = [att]
        }
    }
}

#endif // canImport(UIKit)
