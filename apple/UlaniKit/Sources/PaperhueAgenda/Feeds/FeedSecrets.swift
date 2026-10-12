import Foundation
import Security

/// Feed id -> its address and login (Python: `SecretStore`).
public protocol FeedSecretStore: Sendable {
    /// nil when nothing is stored under `feedID`.
    func get(_ feedID: String) throws -> FeedSecret?
    func set(_ secret: FeedSecret, for feedID: String) throws
    /// Nothing stored is fine.
    func delete(_ feedID: String) throws
}

/// The Keychain: one generic password per feed, service "<bundle id>.ical-feed", account =
/// the feed id, the value `FeedSecret.json`. Readable after the first unlock, on this device
/// only (never synced), in the data protection keychain, which needs the app's entitlements:
/// without them every call throws `FeedError.keychain(status: errSecMissingEntitlement)`.
public struct KeychainFeedSecrets: FeedSecretStore {
    public let service: String

    /// "<the main bundle's id>.ical-feed" (the app's id outside a bundle).
    public static var defaultService: String {
        (Bundle.main.bundleIdentifier ?? "io.github.markhhm.paperhue") + ".ical-feed"
    }

    public init(service: String = KeychainFeedSecrets.defaultService) {
        self.service = service
    }

    /// An item the Keychain holds that is not a `FeedSecret` reads as nil, so the feed is
    /// reported as having no address and can be added again.
    public func get(_ feedID: String) throws -> FeedSecret? {
        var query = item(feedID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw FeedError.keychain(status: status) }
        return (result as? Data).flatMap(FeedSecret.init(json:))
    }

    public func set(_ secret: FeedSecret, for feedID: String) throws {
        let values: [String: Any] = [
            kSecValueData as String: secret.json,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(item(feedID) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item(feedID).merging(values) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw FeedError.keychain(status: status) }
    }

    public func delete(_ feedID: String) throws {
        let status = SecItemDelete(item(feedID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw FeedError.keychain(status: status) }
    }

    private func item(_ feedID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: feedID,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// Secrets kept in memory only: for tests, and for a command line tool that takes the
/// address from stdin or the environment (it has no Keychain entitlement, Apple TN3137).
public final class MemoryFeedSecrets: FeedSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: FeedSecret]  // guarded by lock

    public init(_ values: [String: FeedSecret] = [:]) {
        self.values = values
    }

    /// Everything stored, by feed id.
    public var all: [String: FeedSecret] { lock.withLock { values } }

    public func get(_ feedID: String) -> FeedSecret? { lock.withLock { values[feedID] } }

    public func set(_ secret: FeedSecret, for feedID: String) { lock.withLock { values[feedID] = secret } }

    public func delete(_ feedID: String) { lock.withLock { _ = values.removeValue(forKey: feedID) } }
}
