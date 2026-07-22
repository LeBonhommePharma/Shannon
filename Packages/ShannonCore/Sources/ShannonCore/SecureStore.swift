import Foundation
#if canImport(Security)
import Security
#endif

/// Keychain-backed secret storage, shared by the Mac, iPhone and Watch.
///
/// Shannon's rule is that credentials and agent tokens live in the Keychain
/// and nowhere else — never `UserDefaults`, never a plist, never a CloudKit
/// field. `ShannonStore` and `ShannonPublisher` deliberately have no API that
/// accepts a secret, so there is no path by which one reaches iCloud.
public enum SecureStoreError: Error, Equatable {
    case unavailable
    case notFound
    case duplicateItem
    /// Raw OSStatus, kept so a Keychain failure can be diagnosed from a log.
    case status(Int32)
    case dataCorrupted
}

public struct SecureStore: Sendable {
    /// Shared access group, so a token provisioned on the Mac is readable by
    /// the iPhone app without a second sign-in. Requires the same
    /// `keychain-access-groups` entitlement on every target — see
    /// docs/MULTI_DEVICE.md.
    public static let accessGroup = "com.lebonhommepharma.shannon"
    public static let service = "com.lebonhommepharma.shannon.agent"

    public let service: String
    public let accessGroup: String?
    /// When true, items sync through iCloud Keychain (end-to-end encrypted by
    /// Apple) so the Mac and iPhone converge without re-auth. Device-bound
    /// secrets should pass false.
    public let synchronizable: Bool

    public init(
        service: String = SecureStore.service,
        accessGroup: String? = SecureStore.accessGroup,
        synchronizable: Bool = true
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    #if canImport(Security)

    private func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Stores or replaces a secret.
    ///
    /// Accessibility is `afterFirstUnlock`: background CloudKit refreshes need
    /// the token while the device is locked, and `whenUnlocked` would break
    /// them. It is never `always`, which is unencrypted at rest.
    public func set(_ value: Data, for account: String) throws {
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: value] as CFDictionary
            let updateStatus = SecItemUpdate(baseQuery(account) as CFDictionary, update)
            guard updateStatus == errSecSuccess else {
                throw SecureStoreError.status(updateStatus)
            }
        default:
            throw SecureStoreError.status(status)
        }
    }

    public func set(_ string: String, for account: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw SecureStoreError.dataCorrupted
        }
        try set(data, for: account)
    }

    public func data(for account: String) throws -> Data {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw SecureStoreError.dataCorrupted }
            return data
        case errSecItemNotFound:
            throw SecureStoreError.notFound
        default:
            throw SecureStoreError.status(status)
        }
    }

    public func string(for account: String) throws -> String {
        guard let string = String(data: try data(for: account), encoding: .utf8) else {
            throw SecureStoreError.dataCorrupted
        }
        return string
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.status(status)
        }
    }

    public func contains(_ account: String) -> Bool {
        do {
            _ = try data(for: account)
            return true
        } catch {
            return false
        }
    }

    #else

    public func set(_ value: Data, for account: String) throws {
        throw SecureStoreError.unavailable
    }
    public func set(_ string: String, for account: String) throws {
        throw SecureStoreError.unavailable
    }
    public func data(for account: String) throws -> Data { throw SecureStoreError.unavailable }
    public func string(for account: String) throws -> String { throw SecureStoreError.unavailable }
    public func remove(_ account: String) throws { throw SecureStoreError.unavailable }
    public func contains(_ account: String) -> Bool { false }

    #endif
}

/// Account names used across the three apps, declared once so a typo cannot
/// silently create a second, empty entry.
public enum SecureStoreAccount {
    public static let agentToken = "agent-token"
    public static let bridgeSecret = "bridge-secret"
}
