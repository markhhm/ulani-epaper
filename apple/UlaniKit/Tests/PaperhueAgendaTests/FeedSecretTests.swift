import Foundation
import Security
import Testing
@testable import PaperhueAgenda

/// Whether this test binary may write to the data protection keychain (reading says "not
/// found" either way). A binary without the app's entitlements (`swift test`) gets
/// errSecMissingEntitlement, and the Keychain round trip is skipped.
private enum KeychainAccess {
    static let status: OSStatus = {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.markhhm.paperhue.tests.probe",
            kSecAttrAccount as String: UUID().uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(item.merging([kSecValueData as String: Data("{}".utf8)]) { $1 } as CFDictionary, nil)
        SecItemDelete(item as CFDictionary)
        return status
    }()

    static var entitled: Bool { status == errSecSuccess }
}

/// python/tests/test_feeds.py's secret store tests (the Windows length limit of the Python
/// store does not apply to the Keychain), and the stored form.
@Suite struct FeedSecretTests {
    @Test func secretsRoundTripInMemory() {
        let store = MemoryFeedSecrets()
        store.set(FeedSecret(url: secretAddress, user: "me", password: "pw"), for: "a1")
        #expect(store.get("a1") == FeedSecret(url: secretAddress, user: "me", password: "pw"))
        store.delete("a1")
        #expect(store.get("a1") == nil)
        store.delete("a1")  // twice is fine
    }

    @Test(.enabled(if: KeychainAccess.entitled, "needs the app's keychain entitlement"))
    func secretsRoundTripInTheKeychain() throws {
        let store = KeychainFeedSecrets(service: "io.github.markhhm.paperhue.tests.\(UUID().uuidString)")
        defer { try? store.delete("a1") }
        try store.set(FeedSecret(url: secretAddress, user: "me", password: "pw"), for: "a1")
        #expect(try store.get("a1") == FeedSecret(url: secretAddress, user: "me", password: "pw"))
        try store.set(FeedSecret(url: "https://cloud.example/b"), for: "a1")  // replaced, not added
        #expect(try store.get("a1") == FeedSecret(url: "https://cloud.example/b"))
        try store.delete("a1")
        #expect(try store.get("a1") == nil)
        try store.delete("a1")  // twice is fine
    }

    @Test(.enabled(if: !KeychainAccess.entitled, "runs where the keychain entitlement is missing"))
    func withoutTheEntitlementTheKeychainSaysSo() {
        let store = KeychainFeedSecrets(service: "io.github.markhhm.paperhue.tests.\(UUID().uuidString)")
        let error = #expect(throws: FeedError.self) {
            try store.set(FeedSecret(url: secretAddress), for: "a1")
        }
        #expect(error == .keychain(status: KeychainAccess.status))
        #expect(!"\(error!)".contains("private-"))
    }

    @Test func theServiceIsTheBundleIDWithASuffix() {
        #expect(KeychainFeedSecrets().service == KeychainFeedSecrets.defaultService)
        #expect(KeychainFeedSecrets.defaultService.hasSuffix(".ical-feed"))
    }

    @Test func theStoredFormIsCompactJSON() throws {
        let secret = FeedSecret(url: "https://n/家.ics", user: "me", password: "p\"w\\")
        let text = String(decoding: secret.json, as: UTF8.self)
        #expect(text == #"{"url":"https://n/家.ics","user":"me","password":"p\"w\\"}"#)
        #expect(FeedSecret(json: secret.json) == secret)
        #expect(FeedSecret(json: Data(#"{"url":"https://x/y"}"#.utf8)) == FeedSecret(url: "https://x/y"))
        for bad in ["", "[]", "null", #"{"user":"me"}"#, #"{"url":1}"#, #"{"url":"x","user":2}"#] {
            #expect(FeedSecret(json: Data(bad.utf8)) == nil, "\(bad)")
        }
    }

    @Test func aSecretNeverPrintsItsAddressOrPassword() {
        let secret = FeedSecret(url: secretAddress, user: "me", password: "hunter2")
        var dumped = ""
        dump(secret, to: &dumped)
        for text in [String(describing: secret), String(reflecting: secret), "\(secret)", dumped,
                     String(describing: [secret])] {
            #expect(!text.contains("private-") && !text.contains("hunter2") && !text.contains("me%40gmail"), "\(text)")
        }
        #expect("\(secret)".contains("calendar.google.com"))
    }
}
