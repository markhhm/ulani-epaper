import Foundation
import Testing
@testable import PaperhueAgenda

/// The Python tests' feeds: 個人 in blue, 家務 with an automatic colour and a login.
private let twoFeeds = [Feed(id: "p1", name: "個人", color: "blue"), Feed(id: "h2", name: "家務")]
private let store = MemoryFeedSecrets([
    "p1": FeedSecret(url: "https://g/p.ics"),
    "h2": FeedSecret(url: "https://n/h.ics", user: "me", password: "pw"),
])
private let bodies = ["https://g/p.ics": "ICAL:晨會", "https://n/h.ics": "ICAL:社區大會"]
private let now = OffsetDateTime(wall(2026, 10, 12, 7, 0), utcOffset: 8 * 3600)

/// Every text of `error`, in both languages and as Swift prints it.
private func texts(_ error: (any Error)?) -> [String] {
    guard let error else { return [] }
    var out = [String(describing: error), String(reflecting: error), error.localizedDescription]
    if let feed = error as? FeedError { out += [feed.message(inChinese: true), feed.message(inChinese: false)] }
    return out
}

/// python/tests/test_feeds.py, with a fake loader and a fake parse step (FeedDifferentialTests
/// compares these steps with the Python reference), and once end to end with the iCal parser.
@Suite struct FeedTests {
    // MARK: Addresses

    @Test(arguments: [
        ("  \(secretAddress)\n", secretAddress),
        ("webcal://p01-caldav.icloud.com/published/2/abc", "https://p01-caldav.icloud.com/published/2/abc"),
        ("http://nas.local:5000/cal.ics", "http://nas.local:5000/cal.ics"),
    ])
    func normalizeURL(given: String, url: String) throws {
        #expect(try Feeds.normalizeURL(given) == url)
    }

    @Test(arguments: [
        "", "calendar.google.com/x.ics", "ftp://x/y.ics", "file:///C:/x.ics", "https://",
        "https://me:secret-pw@cloud.example/tasks", "https://g/private-ab cd/basic.ics",
        "https://g/private-abc\n/basic.ics", "https://[bad/private-abc",
    ])
    func badURLsAreRefusedWithoutRepeatingThem(bad: String) {
        let error = #expect(throws: FeedError.self) { try Feeds.normalizeURL(bad) }
        for text in texts(error) {
            #expect(!text.contains("secret-pw") && !text.contains("private-"))
        }
    }

    @Test func refusalsSayWhy() {
        #expect(throws: FeedError.spacesInAddress) { try Feeds.normalizeURL("https://g/a b.ics") }
        #expect(throws: FeedError.notAnAddress) { try Feeds.normalizeURL("ftp://x/y.ics") }
        #expect(throws: FeedError.loginInAddress) { try Feeds.normalizeURL("https://me:pw@x/y.ics") }
    }

    @Test func nonASCIIPathsArePercentEncoded() throws {
        let url = try Feeds.normalizeURL("https://cloud.example/remote.php/dav/calendars/me/家務/?export&componentType=VTODO")
        #expect(url == "https://cloud.example/remote.php/dav/calendars/me/%E5%AE%B6%E5%8B%99/?export&componentType=VTODO")
    }

    @Test func whereShowsOnlyTheHost() {
        #expect(Feeds.host(of: secretAddress) == "calendar.google.com")
        #expect(Feeds.host(of: "not an address") == "?")
    }

    @Test(arguments: [
        (secretAddress, "me@gmail.com"),  // a calendar's own address: its owner, to leave out declined events
        ("https://calendar.google.com/calendar/ical/abc123%40group.calendar.google.com/private-x/basic.ics", ""),
        ("https://outlook.office365.com/owa/calendar/abc/def/calendar.ics", ""),
    ])
    func ownerOfAGoogleAddress(url: String, owner: String) {
        #expect(Feeds.owner(of: url) == owner)
    }

    @Test(arguments: [
        (FeedSecret(url: "https://cloud.example/a", user: "me", password: "pw"), "https://cloud.example/b", true),
        (FeedSecret(url: "https://cloud.example/a", user: "me", password: "pw"), "https://evil.example/b", false),
        (nil, "https://cloud.example/b", false),
    ])
    func aLoginIsKeptOnlyForTheSameHost(old: FeedSecret?, new: String, kept: Bool) {
        let login = Feeds.login(keptFrom: old, for: new)
        #expect([login.user, login.password] == (kept ? ["me", "pw"] : ["", ""]))
    }

    // MARK: Errors

    @Test func errorTextsAreThePythonOnesAndNameTheFeed() {
        let error = FeedError.inFeed(name: "個人", .http(status: 404))
        #expect(error.description == "個人：HTTP 404（找不到：網址可能已重設或刪除）")
        #expect(error.errorDescription == error.description)
        #expect(error.message(inChinese: false) == "個人: HTTP 404 (not found: the address may have been reset or deleted)")
        #expect(error.withoutFeedName == .http(status: 404))
        #expect(FeedError.cannotConnect(host: "calendar.google.com", reason: "timedOut").description
                == "無法連線到 calendar.google.com（timedOut）")
        #expect(FeedError.tooLarge.description == "行事曆大於 20 MB，不處理")
        #expect(FeedError.noFeeds.description == "尚未設定行事曆來源")
        #expect(FeedError.unnamedFeed.description == "every feed needs a name")
        #expect(FeedError.unnamedFeed.errorDescription == "每個行事曆來源都需要名稱")
    }

    // MARK: Fetching every feed

    @Test func fetchReadsEveryFeedWithItsNameAndColour() async throws {
        let loader = FakeLoader(bodies)
        let parser = FakeParser()
        let data = try await Feeds.fetch(twoFeeds, today: day(2026, 10, 12), zone: tpe, now: now, secrets: store,
                                         loader: loader, parse: parser.parse)
        #expect(loader.calls == [["https://g/p.ics", "", ""], ["https://n/h.ics", "me", "pw"]])
        let byTitle = Dictionary(uniqueKeysWithValues: data.events.map { ($0.title, $0) })
        #expect(byTitle["晨會"]?.calendar == "個人" && byTitle["晨會"]?.color == "#0000ff")
        #expect(byTitle["社區大會"]?.calendar == "家務" && byTitle["社區大會"]?.color == "#ff0000")  // automatic
        #expect(data.tasks.map(\.listName) == ["個人", "家務"])
        #expect(data.fetchedAt == now)
        let window = Feeds.window(today: day(2026, 10, 12))
        #expect(parser.contexts.map(\.window) == [window, window])
        #expect(parser.contexts.allSatisfy { $0.zone == tpe && $0.owner.isEmpty })
    }

    @Test func automaticColoursDifferBetweenFeeds() {
        let colours = Feeds.colours([Feed(id: "a", name: "a"), Feed(id: "b", name: "b"),
                                     Feed(id: "c", name: "c", color: "green"), Feed(id: "d", name: "d")])
        #expect(colours["c"] == "#00ff00" && Set(colours.values).count == 4)
    }

    @Test func fetchWindowCoversTheMonthGridAndTheWeeksAhead() {
        let window = Feeds.window(today: day(2026, 10, 31))
        #expect(window.first <= day(2026, 9, 27) && window.last >= day(2026, 11, 30))
        #expect(window == FeedWindow(first: day(2026, 9, 24), last: day(2026, 12, 1)))
        let context = FeedContext(window: window, zone: tpe)
        #expect(context.start == wall(2026, 9, 24, 0, 0).instant(in: tpe))
        #expect(context.end == wall(2026, 12, 1, 0, 0).instant(in: tpe))
    }

    @Test func oneFailingFeedFailsTheFetchAndNamesTheFeed() async {
        let loader = FakeLoader(["https://g/p.ics": "ICAL:晨會", "https://n/h.ics": "FAIL 404"])
        let error = await thrown {
            _ = try await Feeds.fetch(twoFeeds, today: day(2026, 10, 12), zone: tpe, now: now, secrets: store,
                                      loader: loader, parse: FakeParser().parse)
        }
        #expect(error as? FeedError == .inFeed(name: "家務", .http(status: 404)))
        #expect("\(error!)".contains("家務") && "\(error!)".contains("404"))
    }

    @Test func aFeedWithoutAStoredAddressIsReported() async {
        let error = await thrown {
            _ = try await Feeds.fetch(Array(twoFeeds.prefix(1)), today: day(2026, 10, 12), zone: tpe, now: now,
                                      secrets: MemoryFeedSecrets(), loader: FakeLoader(bodies), parse: FakeParser().parse)
        }
        #expect(error as? FeedError == .inFeed(name: "個人", .missingAddress))
    }

    @Test func aFeedThatIsNotACalendarIsReported() async {
        let loader = FakeLoader(["https://g/p.ics": "NOT:<html>sign in</html>"])
        let error = await thrown {
            _ = try await Feeds.fetch(Array(twoFeeds.prefix(1)), today: day(2026, 10, 12), zone: tpe, now: now,
                                      secrets: store, loader: loader, parse: FakeParser().parse)
        }
        #expect(error as? FeedError == .inFeed(name: "個人", .notICalendar))
        #expect("\(error!)" == "個人：收到的不是 iCalendar 資料（網址可能不對，或需要登入）")
    }

    @Test func noFeedsAtAll() async {
        let loader = FakeLoader(bodies)
        let error = await thrown {
            _ = try await Feeds.fetch([], today: day(2026, 10, 12), zone: tpe, now: now, secrets: store,
                                      loader: loader, parse: FakeParser().parse)
        }
        #expect(error as? FeedError == .noFeeds)
        #expect(loader.calls.isEmpty)
    }

    @Test func aLoaderErrorNeverCarriesTheAddress() async {
        let leaky = URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLStringErrorKey: secretAddress])
        let secrets = MemoryFeedSecrets(["p1": FeedSecret(url: secretAddress)])
        let error = await thrown {
            _ = try await Feeds.fetch(Array(twoFeeds.prefix(1)), today: day(2026, 10, 12), zone: tpe, now: now,
                                      secrets: secrets, loader: FailingLoader(error: leaky), parse: FakeParser().parse)
        }
        let expected = FeedError.cannotConnect(host: "calendar.google.com", reason: "cannotFindHost")
        #expect(error as? FeedError == .inFeed(name: "個人", expected))
        for text in texts(error) { #expect(!text.contains("private-") && !text.contains("me%40gmail")) }
    }

    @Test func cancellationPassesThrough() async {
        let error = await thrown {
            _ = try await Feeds.fetch(Array(twoFeeds.prefix(1)), today: day(2026, 10, 12), zone: tpe, now: now,
                                      secrets: store, loader: FailingLoader(error: CancellationError()),
                                      parse: FakeParser().parse)
        }
        #expect(error is CancellationError)
    }

    @Test func aKeychainFailureIsNotBlamedOnTheFeed() async {
        struct Locked: FeedSecretStore {
            func get(_ feedID: String) throws -> FeedSecret? { throw FeedError.keychain(status: -25308) }
            func set(_ secret: FeedSecret, for feedID: String) throws {}
            func delete(_ feedID: String) throws {}
        }
        let error = await thrown {
            _ = try await Feeds.fetch(twoFeeds, today: day(2026, 10, 12), zone: tpe, now: now, secrets: Locked(),
                                      loader: FakeLoader(bodies), parse: FakeParser().parse)
        }
        #expect(error as? FeedError == .keychain(status: -25308))  // as Python: secrets.get is outside the try
    }

    // MARK: Probing one address

    @Test func probeReadsAnAddressNow() async throws {
        let loader = FakeLoader(["https://g/p.ics": "ICAL:晨會"])
        let parser = FakeParser()
        let parsed = try await Feeds.probe("webcal://g/p.ics", today: day(2026, 10, 12), zone: tpe, loader: loader,
                                           parse: parser.parse)
        #expect(parsed.name == "X-WR-CALNAME" && parsed.events.contains { $0.title == "晨會" })
        #expect(loader.calls == [["https://g/p.ics", "", ""]])
        #expect(parser.contexts == [FeedContext(window: Feeds.window(today: day(2026, 10, 12)), zone: tpe)])
    }

    @Test func probeCountsLikeTheSyncWithTheOwner() async throws {
        let url = "https://calendar.google.com/calendar/ical/me%40gmail.com/private-x/basic.ics"
        let parser = FakeParser()
        _ = try await Feeds.probe(url, today: day(2026, 10, 12), zone: tpe, loader: FakeLoader([url: "ICAL:x"]),
                                  parse: parser.parse)
        #expect(parser.contexts.map(\.owner) == ["me@gmail.com"])
    }

    @Test func probeErrorsHaveNoFeedName() async {
        let loader = FakeLoader(["https://g/p.ics": "NOT", "https://g/404.ics": "FAIL 404"])
        for (url, expected) in [("https://g/p.ics", FeedError.notICalendar), ("https://g/404.ics", .http(status: 404)),
                                ("ftp://g/p.ics", .notAnAddress)] {
            let error = await thrown {
                _ = try await Feeds.probe(url, today: day(2026, 10, 12), zone: tpe, loader: loader,
                                          parse: FakeParser().parse)
            }
            #expect(error as? FeedError == expected)
        }
    }

    // MARK: With the iCal parser

    /// feeds.fetch / feeds.probe with the real parser, through a fake loader.
    @Test func fetchAndProbeReadRealCalendars() async throws {
        let google = try String(contentsOf: Repo.url("shared/vectors/ical/google.ics"), encoding: .utf8)
        let todos = try String(contentsOf: Repo.url("shared/vectors/ical/todos.ics"), encoding: .utf8)
        let loader = FakeLoader([secretAddress: google, "https://n/h.ics": todos, "https://bad/x.ics": "<html>"])
        let feeds = [Feed(id: "p1", name: "個人", color: "blue"), Feed(id: "h2", name: "家務")]
        let secrets = MemoryFeedSecrets(["p1": FeedSecret(url: secretAddress),
                                         "h2": FeedSecret(url: "https://n/h.ics")])
        let now = OffsetDateTime(wall(2026, 10, 12, 7, 0), utcOffset: 8 * 3600)
        let data = try await Feeds.fetch(feeds, today: day(2026, 10, 12), zone: tpe, now: now, secrets: secrets,
                                         loader: loader)
        let window = Feeds.window(today: day(2026, 10, 12))
        let expected = try ICal.parse(Data(google.utf8), start: window.first.midnight(in: tpe),
                                      end: window.last.midnight(in: tpe), zone: tpe, name: "個人", color: "#0000ff",
                                      owner: "me@gmail.com").events
        #expect(data.events.filter { $0.calendar == "個人" } == expected && expected.count > 10)
        #expect(data.events.contains { $0.title == "晨會" && $0.start == at(2026, 10, 12, 9, 0) })
        #expect(data.events.filter { $0.calendar == "家務" }.map(\.title) == ["社區大會"])
        #expect(data.events.allSatisfy { $0.color == ($0.calendar == "個人" ? "#0000ff" : "#ff0000") })
        #expect(data.tasks.count == 6 && data.tasks.allSatisfy { $0.listName == "家務" })
        #expect(data.fetchedAt == now)

        let probed = try await Feeds.probe("webcal://n/h.ics", today: day(2026, 10, 12), zone: tpe, loader: loader)
        #expect(probed.name == "家務" && probed.tasks.count == 6 && probed.events.allSatisfy { $0.color.isEmpty })
        await #expect(throws: FeedError.notICalendar) {
            _ = try await Feeds.probe("https://bad/x.ics", today: day(2026, 10, 12), zone: tpe, loader: loader)
        }
    }

    // MARK: Adding and removing

    @Test func newAndRemovedFeeds() throws {
        var feeds: [Feed] = []
        let secrets = MemoryFeedSecrets()
        let feed = try Feeds.add(name: " 學校 ", url: "webcal://school/x.ics", color: "green", to: &feeds,
                                 secrets: secrets)
        #expect(feeds == [feed] && feed.name == "學校" && feed.color == "green")
        #expect(NoteStore.isNoteID(feed.id))
        #expect(secrets.get(feed.id) == FeedSecret(url: "https://school/x.ics"))
        #expect(throws: FeedError.invalidFeedColour(feed: "bad colour")) {
            try Feeds.add(name: "bad colour", url: "https://x/y.ics", color: "purple", to: &feeds, secrets: secrets)
        }
        #expect(feeds == [feed] && secrets.all.count == 1)  // nothing half-added
        try Feeds.remove(feed, from: &feeds, secrets: secrets)
        #expect(feeds.isEmpty && secrets.all.isEmpty)
    }

    @Test func aStoreThatRefusesAddsNothing() {
        struct Refusing: FeedSecretStore {
            func get(_ feedID: String) throws -> FeedSecret? { nil }
            func set(_ secret: FeedSecret, for feedID: String) throws { throw FeedError.keychain(status: -34018) }
            func delete(_ feedID: String) throws {}
        }
        var feeds: [Feed] = []
        #expect(throws: FeedError.keychain(status: -34018)) {
            try Feeds.add(name: "學校", url: "https://school/x.ics", to: &feeds, secrets: Refusing())
        }
        #expect(feeds.isEmpty)
    }

    @Test func aNewIDNeverRepeatsAnOldOne() throws {
        var feeds = [Feed(id: "aaaaaaaa", name: "a")]
        var ids = ["aaaaaaaa", "bbbbbbbb"].makeIterator()
        let feed = try Feeds.add(name: "b", url: "https://b/x.ics", to: &feeds, secrets: MemoryFeedSecrets(),
                                 id: { ids.next()! })
        #expect(feed.id == "bbbbbbbb")
    }
}
