import Foundation
import Testing
@testable import PaperhueAgenda

// Fakes for the calendar source tests (no network, no Keychain) and the expectations computed
// with the Python reference (Differential/make_feed_expectations.py).

/// python/tests/test_feeds.py's SECRET: a Google secret address.
let secretAddress = "https://calendar.google.com/calendar/ical/me%40gmail.com/private-0123456789abcdef/basic.ics"

/// Answers from a table, URL -> body, and records every call (Python tests: `fake_download`).
/// A body "FAIL <code>" throws that HTTP status, "TIMEOUT" a connection failure; an address
/// not in the table cannot be reached.
final class FakeLoader: FeedLoader, @unchecked Sendable {
    private let lock = NSLock()
    private let bodies: [String: String]
    private var recorded: [[String]] = []

    init(_ bodies: [String: String]) { self.bodies = bodies }

    /// [url, user, password] of each call, in order.
    var calls: [[String]] { lock.withLock { recorded } }

    func load(_ url: String, user: String, password: String) async throws -> Data {
        lock.withLock { recorded.append([url, user, password]) }
        guard let body = bodies[url] else {
            throw FeedError.cannotConnect(host: Feeds.host(of: url), reason: "cannotFindHost")
        }
        if body.hasPrefix("FAIL "), let status = Int(body.dropFirst(5)) { throw FeedError.http(status: status) }
        if body == "TIMEOUT" { throw FeedError.cannotConnect(host: Feeds.host(of: url), reason: "TimeoutError") }
        return Data(body.utf8)
    }
}

/// A loader that fails with whatever error it is given.
struct FailingLoader: FeedLoader {
    let error: any Error & Sendable

    func load(_ url: String, user: String, password: String) async throws -> Data { throw error }
}

/// What `FakeParser` returns.
struct FakeContents: FeedContents, Equatable {
    var name: String
    var events: [Event]
    var tasks: [AgendaTask]
}

struct NotACalendar: Error {}

/// Stands in for the iCal parser, as the generator's Recorder does: a body starting with
/// "NOT" is not a calendar; any other gives one event ten days into the window and one to-do,
/// titled with what follows the first ":", carrying the context's name and colour.
final class FakeParser {
    private(set) var bodies: [String] = []
    private(set) var contexts: [FeedContext] = []

    func parse(_ data: Data, _ context: FeedContext) throws -> FakeContents {
        let body = String(decoding: data, as: UTF8.self)
        bodies.append(body)
        contexts.append(context)
        if body.hasPrefix("NOT") { throw NotACalendar() }
        let title = body.split(separator: ":", maxSplits: 1).last.map(String.init) ?? body
        let start = context.start.addingTimeInterval(10 * 86_400)
        let event = Event(title: title, start: .at(start, in: context.zone), end: .at(start + 3600, in: context.zone),
                          calendar: context.name, color: context.color)
        return FakeContents(name: context.name.isEmpty ? "X-WR-CALNAME" : context.name, events: [event],
                            tasks: [AgendaTask(title: "\(title) task", listName: context.name)])
    }
}

/// The error `body` throws, or nil.
func thrown(_ body: () async throws -> Void) async -> (any Error)? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

/// Differential/feed-expectations.json.
struct FeedExpectations: Decodable, Sendable {
    struct Normalize: Decodable, Sendable {
        let input: String
        let url: String?
        let error: String?
    }

    struct Host: Decodable, Sendable {
        let url: String
        let host: String?  // nil: Python raises ValueError
    }

    struct Owner: Decodable, Sendable {
        let url: String
        let owner: String?  // nil: Python raises ValueError
    }

    struct Login: Decodable, Sendable {
        let old: [String: String]?
        let new: String
        let login: [String]
    }

    struct Colours: Decodable, Sendable {
        let feeds: [[String]]
        let colours: [String: String]
    }

    struct Validate: Decodable, Sendable {
        let feeds: [[String]]
        let error: String?
    }

    struct HTTP: Decodable, Sendable {
        let code: Int
        let error: String
    }

    struct Auth: Decodable, Sendable {
        let user: String
        let password: String
        let authorization: String?
        let timeout: Int
        let error: String
    }

    /// One call of ical.parse, as the Recorder saw it (instants in microseconds since 1970).
    struct Parse: Decodable, Sendable {
        let body: String
        let start: Int
        let end: Int
        let startWall: String
        let endWall: String
        let name: String
        let color: String
        let owner: String
        enum CodingKeys: String, CodingKey {
            case body, start, end, startWall = "start_wall", endWall = "end_wall", name, color, owner
        }
    }

    struct Fetch: Decodable, Sendable {
        let name: String
        let feeds: [[String]]
        let secrets: [String: [String: String]]
        let today: String
        let zone: String
        let now: String
        let events: [[String]]?
        let tasks: [[String]]?
        let fetchedAt: String?
        let error: String?
        let errorType: String?
        let downloads: [[String]]
        let parses: [Parse]
        enum CodingKeys: String, CodingKey {
            case name, feeds, secrets, today, zone, now, events, tasks, fetchedAt = "fetched_at", error,
                 errorType = "error_type", downloads, parses
        }
    }

    struct Probe: Decodable, Sendable {
        let url: String
        let user: String
        let password: String
        let today: String
        let zone: String
        let result: String?
        let error: String?
        let downloads: [[String]]
        let parses: [Parse]
    }

    struct NewFeed: Decodable, Sendable {
        let name: String
        let url: String
        let color: String
        let user: String
        let password: String
        let feed: [String]?
        let secret: [String: String]?
        let error: String?
        let errorType: String?
        let feeds: Int
        let stored: Int
        enum CodingKeys: String, CodingKey {
            case name, url, color, user, password, feed, secret, error, errorType = "error_type", feeds, stored
        }
    }

    let normalize: [Normalize]
    let `where`: [Host]
    let owner: [Owner]
    let login: [Login]
    let colours: [Colours]
    let autoColours: [String]
    let validate: [Validate]
    let windows: [[String]]
    let http: [HTTP]
    let auth: [Auth]
    let headers: [String: String]
    let maxBytes: Int
    let timeout: Int
    let fetch: [Fetch]
    let probe: [Probe]
    let newFeed: [NewFeed]

    enum CodingKeys: String, CodingKey {
        case normalize, `where`, owner, login, colours, autoColours = "auto_colours", validate, windows, http, auth,
             headers, maxBytes = "max_bytes", timeout, fetch, probe, newFeed = "new_feed"
    }

    private static let loaded = Result<FeedExpectations, any Error> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Differential/feed-expectations.json")
        return try JSONDecoder().decode(FeedExpectations.self, from: Data(contentsOf: url))
    }

    static func load() throws -> FeedExpectations { try loaded.get() }
}

extension Feed {
    /// [id, name, color] as the expectations write a feed.
    init(_ triple: [String]) {
        self.init(id: triple[0], name: triple[1], color: triple[2])
    }
}
