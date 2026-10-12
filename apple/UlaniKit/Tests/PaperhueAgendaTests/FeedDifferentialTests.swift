import Foundation
import Testing
@testable import PaperhueAgenda

/// The calendar source rules against the Python reference (Differential/feed-expectations.json,
/// from make_feed_expectations.py): every case must give exactly what Python gives.
@Suite struct FeedDifferentialTests {
    let expected: FeedExpectations

    init() throws { expected = try FeedExpectations.load() }

    @Test func normalizeURL() {
        #expect(expected.normalize.count > 100)
        for c in expected.normalize {
            do {
                let url = try Feeds.normalizeURL(c.input)
                #expect(url == c.url, "\(c.input.debugDescription)")
            } catch {
                #expect("\(error)" == c.error, "\(c.input.debugDescription)")
            }
        }
    }

    @Test func hostOfAnAddress() {
        for c in expected.where {
            #expect(Feeds.host(of: c.url) == c.host ?? "?", "\(c.url.debugDescription)")
        }
    }

    @Test func ownerOfAnAddress() {
        for c in expected.owner {
            let owner = Feeds.owner(of: c.url)
            #expect(Array(owner.unicodeScalars) == Array((c.owner ?? "").unicodeScalars), "\(c.url.debugDescription)")
        }
    }

    @Test func loginKeptForTheSameHost() {
        for c in expected.login {
            // Python's {} and {"url": ""} keep nothing, like nil
            let old = c.old.flatMap { o in
                o["url"].map { FeedSecret(url: $0, user: o["user"] ?? "", password: o["password"] ?? "") }
            }
            let login = Feeds.login(keptFrom: old, for: c.new)
            #expect([login.user, login.password] == c.login, "\(String(describing: c.old)) -> \(c.new)")
        }
    }

    @Test func automaticColours() {
        #expect(Feeds.autoColours == expected.autoColours)
        for c in expected.colours {
            #expect(Feeds.colours(c.feeds.map(Feed.init)) == c.colours, "\(c.feeds)")
        }
    }

    @Test func settingsChecks() {
        for c in expected.validate {
            do {
                try Feed.validate(c.feeds.map(Feed.init))
                #expect(c.error == nil, "\(c.feeds)")
            } catch {
                #expect("\(error)" == c.error, "\(c.feeds)")
            }
        }
    }

    @Test func fetchWindows() throws {
        #expect(expected.windows.count == 1827)
        for w in expected.windows {
            let window = Feeds.window(today: try day(iso: w[0]))
            #expect([window.first.iso, window.last.iso] == [w[1], w[2]], "\(w[0])")
        }
    }

    @Test func httpErrorTexts() {
        #expect(expected.http.count == 300)
        for c in expected.http {
            #expect(FeedError.http(status: c.code).description == c.error)
        }
    }

    @Test func requestHeadersAndBasicAuth() throws {
        #expect(Feeds.maxBytes == expected.maxBytes && Int(Feeds.timeout) == expected.timeout)
        for c in expected.auth {
            let request = try #require(URLSessionFeedLoader.request(secretAddress, user: c.user, password: c.password,
                                                                    userAgent: "Paperhue/test"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == c.authorization, "\(c.user):\(c.password)")
            #expect(Int(request.timeoutInterval) == c.timeout)
            #expect(FeedError.cannotConnect(host: Feeds.host(of: secretAddress), reason: "TimeoutError").description == c.error)
            #expect(request.value(forHTTPHeaderField: "Accept") == expected.headers["Accept"])
            #expect(request.url?.absoluteString == secretAddress)
        }
        #expect(expected.headers["User-agent"]?.hasPrefix("Paperhue/") == true)
        #expect(URLSessionFeedLoader.defaultUserAgent.hasPrefix("Paperhue"))
    }

    @Test func fetchEveryFeed() async throws {
        #expect(expected.fetch.count > 40)
        for c in expected.fetch {
            let zone = try zone(c.zone)
            let secrets = MemoryFeedSecrets(c.secrets.mapValues {
                FeedSecret(url: $0["url"] ?? "", user: $0["user"] ?? "", password: $0["password"] ?? "")
            })
            let loader = FakeLoader(Self.bodies)
            let parser = FakeParser()
            let label = "\(c.name) \(c.today) \(c.zone)"
            let now = try #require(OffsetDateTime(iso: c.now))
            do {
                let data = try await Feeds.fetch(c.feeds.map(Feed.init), today: try day(iso: c.today), zone: zone,
                                                 now: now, secrets: secrets, loader: loader, parse: parser.parse)
                #expect(c.error == nil, "\(label)")
                #expect(data.events.map { [$0.title, $0.calendar, $0.color] } == c.events, "\(label)")
                #expect(data.tasks.map { [$0.title, $0.listName] } == c.tasks, "\(label)")
                #expect(data.fetchedAt?.iso == c.fetchedAt, "\(label)")
            } catch {
                #expect("\(error)" == c.error, "\(label)")
                #expect((error as? FeedError == .noFeeds) == (c.errorType == "NoFeeds"), "\(label)")
            }
            #expect(loader.calls == c.downloads, "\(label)")
            Self.compare(parser, c.parses, zone: zone, label)
        }
    }

    @Test func probeOneAddress() async throws {
        for c in expected.probe {
            let zone = try zone(c.zone)
            let loader = FakeLoader(Self.bodies.merging([
                "https://calendar.google.com/calendar/ical/Me%40Gmail.com/private-x/basic.ics": "ICAL:g",
            ]) { $1 })
            let parser = FakeParser()
            let label = "\(c.url) \(c.today) \(c.zone)"
            do {
                let parsed = try await Feeds.probe(c.url, user: c.user, password: c.password, today: try day(iso: c.today),
                                                   zone: zone, loader: loader, parse: parser.parse)
                #expect(parsed.name == c.result, "\(label)")
            } catch {
                #expect("\(error)" == c.error, "\(label)")
            }
            #expect(loader.calls == c.downloads, "\(label)")
            Self.compare(parser, c.parses, zone: zone, label)
        }
    }

    @Test func addingAFeed() {
        for c in expected.newFeed {
            var feeds: [Feed] = []
            let secrets = MemoryFeedSecrets()
            do {
                let feed = try Feeds.add(name: c.name, url: c.url, color: c.color, user: c.user, password: c.password,
                                         to: &feeds, secrets: secrets)
                #expect([feed.name, feed.color] == c.feed, "\(c.name)")
                let stored = secrets.get(feed.id)
                #expect([stored?.url, stored?.user, stored?.password]
                        == [c.secret?["url"], c.secret?["user"], c.secret?["password"]], "\(c.name)")
            } catch {
                #expect("\(error)" == c.error, "\(c.name)")
            }
            #expect(feeds.count == c.feeds && secrets.all.count == c.stored, "\(c.name)")
        }
    }

    // MARK: -

    /// The generator's download table (make_feed_expectations.py BODIES).
    static let bodies = [
        "https://calendar.google.com/calendar/ical/Me%40Gmail.com/private-x/basic.ics": "ICAL:晨會",
        "https://n/h.ics": "ICAL:社區大會", "https://school.example/s.ics": "ICAL:段考", "https://u/x.ics": "ICAL:u",
        "https://bad/404.ics": "FAIL 404", "https://bad/400.ics": "FAIL 400", "https://bad/html.ics": "NOT:<html>sign in</html>",
        "https://bad/timeout.ics": "TIMEOUT", "https://school.example/x.ics": "ICAL:probe",
    ]

    /// What the fake parse step was given against what ical.parse was given.
    static func compare(_ parser: FakeParser, _ parses: [FeedExpectations.Parse], zone: TimeZone, _ label: String) {
        #expect(parser.bodies == parses.map(\.body), "\(label)")
        #expect(parser.contexts.map(\.name) == parses.map(\.name), "\(label)")
        #expect(parser.contexts.map(\.color) == parses.map(\.color), "\(label)")
        #expect(parser.contexts.map(\.owner) == parses.map(\.owner), "\(label)")
        #expect(parser.contexts.map { LocalDateTime.epochMicroseconds($0.start) } == parses.map(\.start), "\(label)")
        #expect(parser.contexts.map { LocalDateTime.epochMicroseconds($0.end) } == parses.map(\.end), "\(label)")
        #expect(parser.contexts.map { LocalDateTime(midnightOf: $0.window.first).iso } == parses.map(\.startWall),
                "\(label)")
        #expect(parser.contexts.map { LocalDateTime(midnightOf: $0.window.last).iso } == parses.map(\.endWall),
                "\(label)")
        #expect(parser.contexts.allSatisfy { $0.zone == zone }, "\(label)")
    }
}
