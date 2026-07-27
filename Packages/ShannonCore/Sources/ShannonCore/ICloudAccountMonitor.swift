import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - Account change monitoring (Apple)

/// Observes system iCloud account transitions and exposes a pure status snapshot.
///
/// On non-Apple / no-CloudKit hosts this is a no-op static `.unsupported` source.
/// On Apple platforms with CloudKit it listens for `CKAccountChanged` and re-queries
/// the Shannon container. Never stores credentials — only presence.
@MainActor
public final class ICloudAccountMonitor {
    /// Latest known status (starts undetermined until the first refresh).
    public private(set) var status: ICloudAccountStatus

    /// Fired after every status change (including the first resolve when it differs).
    public var onChange: ((ICloudAccountStatus) -> Void)?

    private let reader: any ICloudAccountStatusReading
    /// Notification token — cleared on stop; nonisolated(unsafe) for deinit hygiene.
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?

    /// - Parameters:
    ///   - initial: Seed status before the first async refresh (tests inject).
    ///   - reader: Status source. Defaults to CloudKit on Apple, unsupported elsewhere.
    ///   - observeSystemChanges: Register for `CKAccountChanged` when CloudKit exists.
    public init(
        initial: ICloudAccountStatus = .couldNotDetermine,
        reader: (any ICloudAccountStatusReading)? = nil,
        observeSystemChanges: Bool = true
    ) {
        #if canImport(CloudKit)
        self.reader = reader ?? CloudKitAccountStatusReader()
        self.status = initial
        #else
        self.reader = reader ?? StaticICloudAccountStatusReader(.unsupported)
        self.status = .unsupported
        #endif

        if observeSystemChanges {
            startObserving()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Query the reader and publish if the status changed.
    public func refresh() async {
        let next = await reader.currentStatus()
        apply(next)
    }

    /// Synchronous apply for tests / injected transitions.
    public func apply(_ next: ICloudAccountStatus) {
        let changed = next != status
        status = next
        if changed {
            onChange?(next)
        }
    }

    /// Whether CloudKit publish/drain is allowed right now (fail-closed).
    public var canUseCloudKit: Bool {
        ICloudAccountPolicy.canUseCloudKit(status)
    }

    private func startObserving() {
        #if canImport(CloudKit)
        observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshTask?.cancel()
                self.refreshTask = Task { @MainActor in
                    await self.refresh()
                }
            }
        }
        #endif
        refreshTask = Task { @MainActor in
            await self.refresh()
        }
    }
}
