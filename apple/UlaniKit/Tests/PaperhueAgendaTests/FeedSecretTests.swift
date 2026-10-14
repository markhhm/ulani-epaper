import Foundation
import Security
import Testing
@testable import PaperhueAgenda

/// `PAPERHUE_KEYCHAIN_TEST=1`: the Keychain round trip may write the default keychain. Never
/// set by default, so a developer's own login keychain is never written; apple.yml sets it
/// with an unlocked temporary keychain as the default.
private let keychainTestAllowed = ProcessInfo.processInfo.environment["PAPERHUE_KEYCHAIN_TEST"] == "1"

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

    /// The release has no keychain access group (no provisioning profile, Apple TN3137), so
    /// the query must not ask for the data protection keychain: every call would fail with
    /// errSecMissingEntitlement. Nothing else changes.
    @Test func theReleaseIsSignedAdHocSoTheFileBasedKeychain() {
        let item = KeychainFeedSecrets(service: "io.github.markhhm.paperhue.tests").item("a1")
        #expect(!item.keys.contains(kSecUseDataProtectionKeychain as String))
        #expect(!item.keys.contains(kSecAttrAccessGroup as String))
        #expect(item[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(item[kSecAttrService as String] as? String == "io.github.markhhm.paperhue.tests")
        #expect(item[kSecAttrAccount as String] as? String == "a1")
    }

    /// Writes the default keychain: run only with PAPERHUE_KEYCHAIN_TEST=1 (see above).
    @Test(.enabled(if: keychainTestAllowed,
                   "set PAPERHUE_KEYCHAIN_TEST=1 with an unlocked temporary default keychain (as apple.yml does)"))
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
