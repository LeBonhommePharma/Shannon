import Combine
import Foundation

/// Live multi-device / iCloud operator status for the menu-bar popover footer.
///
/// Held as an ``ObservableObject`` so reopen and account transitions update the
/// SwiftUI tree without rebuilding the whole popover. Source of truth is
/// ``CloudPublisher/multiDeviceStatusLine`` (full operator line).
@MainActor
final class MultiDeviceStatusModel: ObservableObject {
    /// Full operator line, e.g. `Multi-device: on (iCloud)` or
    /// `Multi-device: sign in to iCloud (System Settings → Apple ID)`.
    @Published private(set) var line: String

    init(line: String = "Multi-device: in-memory") {
        self.line = line
    }

    /// Replace the displayed line (called on popover open and account change).
    func update(_ line: String) {
        let next = line.isEmpty ? "Multi-device: in-memory" : line
        if self.line != next {
            self.line = next
        }
    }
}
