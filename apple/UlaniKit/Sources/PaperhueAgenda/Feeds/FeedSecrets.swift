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
/// the feed id, the value `FeedSecret.json`.
///
/// The items are in the file-based (login) keychain, for every build. The data protection
/// keychain needs a keychain access group, which only a provisioning profile from an Apple
/// developer team can authorise (Apple TN3137); the release is signed ad hoc, so every call to
/// it would throw `FeedError.keychain(status: errSecMissingEntitlement)`. File-based items
/// are never synced to iCloud: the address stays on this Mac. The login keychain is unlocked
/// when the user logs in.
///
/// macOS trusts the app that created an item. An ad hoc signature changes with every version,
/// so after an update macOS asks once per calendar source whether Paperhue may use it (the
/// user enters their Mac password and chooses Always Allow, 「永遠允許」). The scheduled sync
/// runs the same executable, so the question can also come when it reads an address first.
/// A user who denies or cancels it gets `FeedError.keychain(status:)` with errSecAuthFailed
/// or errSecUserCanceled.
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
        let values: [String: Any] = [kSecValueData as String: secret.json]
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

    /// The query naming `feedID`'s item. Nothing in it selects the data protection keychain
    /// (no `kSecUseDataProtectionKeychain`, no access group): see the type's comment.
    func item(_ feedID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: feedID,
        ]
    }
}

/// Secrets kept in memory only: for tests, and for the public Taiwan holidays calendar that
/// `PageSync` reads when no calendar source is set up (its address is no secret, so nothing is
/// looked up in the Keychain). The package's command line tool reads no calendars.
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
