import Foundation

/// One calendar source as the settings keep it, in display order (python/src/ulani_epaper/config.py,
/// `Feed`). Its address is not here: it lives in a `FeedSecretStore` under `id`.
public struct Feed: Hashable, Sendable, Codable, Identifiable {
    /// 8 random hex characters for a new feed (`randomID()`); settings may hold any id that
    /// passes `validate`.
    public var id: String
    /// Shown on the pages ("個人", "學校").
    public var name: String
    /// A panel colour name of `Feed.colours`, "#rrggbb", or "" (chosen by `Feeds.colours`).
    public var color: String

    public init(id: String, name: String, color: String = "") {
        self.id = id
        self.name = name
        self.color = color
    }

    /// The colour names a feed may have (Python: `FEED_COLOURS`).
    public static let colours = ["red", "orange", "yellow", "green", "blue", "black"]

    /// A new feed id: 4 random bytes as 8 lower-case hex characters (Python: `secrets.token_hex(4)`).
    public static func randomID() -> String { NoteStore.randomToken() }

    /// The feed part of Python's `Settings.validate`: ids unique and simple, every feed named,
    /// colours known. Throws the first problem as a `FeedError` settings case.
    public static func validate(_ feeds: [Feed]) throws {
        let ids = feeds.map(\.id)
        let simple = ids.allSatisfy { id in
            let b = Array(id.utf8)
            return (1...40).contains(b.count) && b.allSatisfy { isASCIIAlphanumeric($0) || $0 == 0x5F || $0 == 0x2D }
        }
        // Python's set compares code points; ids that are not plain ASCII are refused anyway.
        if !simple || Set(ids.map { Array($0.unicodeScalars) }).count != ids.count {
            throw FeedError.invalidFeedIDs(ids)
        }
        for feed in feeds {
            if Note.strip(feed.name.unicodeScalars).isEmpty { throw FeedError.unnamedFeed }
            if !feed.color.isEmpty, !colours.contains(feed.color), !isHexColour(feed.color) {
                throw FeedError.invalidFeedColour(feed: feed.name)
            }
        }
    }

    /// "#" and six ASCII hex digits, either case.
    static func isHexColour(_ text: String) -> Bool {
        let b = Array(text.utf8)
        return b.count == 7 && b[0] == 0x23 && b.dropFirst().allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func isASCIIAlphanumeric(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
    }
}

/// A feed's address and optional HTTP Basic login, as a `FeedSecretStore` keeps it. The
/// address is a password: printing or dumping a secret shows only its host.
public struct FeedSecret: Hashable, Sendable {
    public var url: String
    public var user: String
    public var password: String

    public init(url: String, user: String = "", password: String = "") {
        self.url = url
        self.user = user
        self.password = password
    }

    /// The stored form: {"url":…,"user":…,"password":…} (compact JSON, as Python's
    /// `json.dumps(..., separators=(",", ":"))` writes it, without escaping non-ASCII).
    public var json: Data {
        let text = "{\"url\":\(PythonJSON.quoted(url)),\"user\":\(PythonJSON.quoted(user)),"
            + "\"password\":\(PythonJSON.quoted(password))}"
        return Data(text.utf8)
    }

    /// The stored form read back; nil unless it is a JSON object whose "url" is a string
    /// ("user" and "password" default to "").
    public init?(json: Data) {
        guard let object = try? PythonJSON.parse(json) as? [String: Any],
              let url = object["url"].flatMap(PythonJSON.string) else { return nil }
        let user = object["user"].map { PythonJSON.string($0) } ?? ""
        let password = object["password"].map { PythonJSON.string($0) } ?? ""
        guard let user, let password else { return nil }
        self.init(url: url, user: user, password: password)
    }
}

extension FeedSecret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Only the host, whether a login is stored: never the address or the password.
    public var description: String {
        "FeedSecret(host: \(Feeds.host(of: url)), login: \(user.isEmpty && password.isEmpty ? "no" : "yes"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: ["host": Feeds.host(of: url)]) }
}
