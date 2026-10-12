import Foundation

/// Calendar sources: .ics addresses fetched straight from the calendar service, as in
/// python/src/ulani_epaper/feeds.py (shared/AGENDA.md section 4).
///
/// A feed is any iCalendar address: Google Calendar's "secret address in iCal format", an
/// Outlook / iCloud / Proton published calendar, a Nextcloud or other CalDAV export link
/// (optionally with a user name and app password). No account or API of anyone else is
/// involved. An address that is not public is a password in itself, so it is kept in the
/// Keychain (`KeychainFeedSecrets`), never in the settings, errors or logs; what is fetched is
/// parsed in memory and never written anywhere.
public enum Feeds {
    /// Seconds a request may wait for the server.
    public static let timeout: TimeInterval = 30
    /// A feed larger than this is refused (20 MB).
    public static let maxBytes = 20 * 1024 * 1024
    /// The colours given to feeds without one, in this order.
    public static let autoColours = ["blue", "red", "green", "orange", "yellow", "black"]

    // MARK: Addresses

    /// A pasted address as it is fetched (Python: `normalize_url`): outer whitespace trimmed,
    /// webcal:// and webcals:// become https://, the path and query percent-encoded where
    /// URLs cannot carry a character (non-ASCII among them). Only http and https addresses
    /// with a host and no user name or password are taken. Errors never repeat the address.
    public static func normalizeURL(_ text: String) throws -> String {
        var url = Note.strip(text.unicodeScalars)
        // Python: url.lower().startswith(("webcal://", "webcals://")), compared by code point
        let head = url.unicodeScalars.prefix(10).map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }
        for scheme in ["webcal://", "webcals://"] where head.starts(with: scheme.unicodeScalars) {
            url = "https://" + PythonURL.string(url.unicodeScalars.dropFirst(scheme.count))
            break
        }
        if url.unicodeScalars.contains(where: { Note.isPythonSpace($0) || $0.value < 32 }) {
            throw FeedError.spacesInAddress
        }
        guard var parts = try? PythonURL(parsing: url), parts.hostname != nil,
              parts.scheme == "http" || parts.scheme == "https" else {
            throw FeedError.notAnAddress
        }
        let (user, password) = parts.userInfo
        if !(user ?? "").isEmpty || !(password ?? "").isEmpty { throw FeedError.loginInAddress }
        let safe = "/%:@!$&'()*+,;=-._~?"
        parts.path = PythonURL.quote(parts.path, safe: safe)
        parts.query = PythonURL.quote(parts.query ?? "", safe: safe)
        return parts.unparsed
    }

    /// Only the host of an address, for display: the path is the secret (Python: `where`).
    /// "?" when there is none.
    public static func host(of url: String) -> String {
        (try? PythonURL(parsing: url))?.hostname ?? "?"
    }

    /// The e-mail of the person whose own Google calendar this secret address is
    /// (calendar.google.com/calendar/ical/<e-mail>/private-…), lower-cased; "" for any other
    /// address, including secondary and shared calendars (…@group.calendar.google.com). Used
    /// only in memory, to leave out invitations that person declined.
    public static func owner(of url: String) -> String {
        guard let parts = try? PythonURL(parsing: url), parts.hostname == "calendar.google.com" else { return "" }
        let segments = parts.path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            .map(PythonURL.string)
        guard let ical = segments.firstIndex(of: "ical"), segments.last != "ical" else { return "" }
        let id = PythonURL.unquote(segments[ical + 1])
        // Python's endswith compares code points; Swift's hasSuffix would compare characters.
        let suffix = Array(".calendar.google.com".unicodeScalars)
        if !id.unicodeScalars.contains("@") || Array(id.unicodeScalars).suffix(suffix.count) == suffix[...] {
            return ""
        }
        return PythonURL.pythonLower(id)
    }

    /// The stored user name and password, but only if the new address is on the same host: a
    /// password must never be sent to some other server (Python: `login_for`).
    public static func login(keptFrom old: FeedSecret?, for newURL: String) -> (user: String, password: String) {
        if let old, !old.url.isEmpty, PaperhueAgenda.compareCodePoints(host(of: old.url), host(of: newURL)) == 0 {
            return (old.user, old.password)
        }
        return ("", "")
    }

    // MARK: Window and colours

    /// Days to read: the 6-week grid of today's month and at least a month ahead (Python:
    /// `window`).
    public static func window(today: LocalDate) -> FeedWindow {
        let first = today.firstOfMonth
        return FeedWindow(first: first.adding(days: -7),
                          last: max(first.firstOfNextMonth.adding(days: 14), today.adding(days: 31)))
    }

    /// Feed id -> "#rrggbb": its own colour, else the next automatic colour that no feed has
    /// taken (all of them again once every one is taken). Python: `colours`.
    public static func colours(_ feeds: [Feed]) -> [String: String] {
        let taken = Set(feeds.map(\.color).filter { !$0.isEmpty })
        var spare = autoColours.filter { !taken.contains($0) }
        if spare.isEmpty { spare = autoColours }
        var out: [String: String] = [:]
        var i = 0
        for feed in feeds {
            if !feed.color.isEmpty {
                out[feed.id] = hex(feed.color)
            } else {
                out[feed.id] = hex(spare[i % spare.count])
                i += 1
            }
        }
        return out
    }

    /// "#rrggbb" of a panel colour name (python/src/ulani_epaper/image.py `PALETTE`), or a
    /// "#…" value lower-cased. "" for an unknown name (Python raises; `Feed.validate` refuses one).
    static func hex(_ nameOrHex: String) -> String {
        if nameOrHex.unicodeScalars.first == "#" { return PythonURL.pythonLower(nameOrHex) }
        let palette = ["black": "#000000", "white": "#ffffff", "green": "#00ff00", "blue": "#0000ff",
                       "red": "#ff0000", "yellow": "#ffff00", "orange": "#ff7d00"]
        return palette[nameOrHex] ?? ""
    }

    // MARK: Adding and removing

    /// Keeps the address in `secrets` and appends the feed to `feeds` (the caller saves the
    /// settings). The name is trimmed; the address normalized. Nothing is half-added: if the
    /// settings check or the secret store refuses, `feeds` is left as it was. Python: `new_feed`.
    @discardableResult
    public static func add(name: String, url: String, color: String = "", user: String = "", password: String = "",
                           to feeds: inout [Feed], secrets: any FeedSecretStore,
                           id: () -> String = Feed.randomID) throws -> Feed {
        let url = try normalizeURL(url)
        var newID = id()
        while feeds.contains(where: { $0.id == newID }) { newID = id() }
        let feed = Feed(id: newID, name: Note.strip(name.unicodeScalars), color: color)
        try Feed.validate(feeds + [feed])
        try secrets.set(FeedSecret(url: url, user: user, password: password), for: feed.id)
        feeds.append(feed)
        return feed
    }

    /// Forgets a feed and its address (the caller saves the settings). Python: `remove_feed`.
    public static func remove(_ feed: Feed, from feeds: inout [Feed], secrets: any FeedSecretStore) throws {
        try secrets.delete(feed.id)
        feeds.removeAll { $0.id == feed.id }
    }

    // MARK: Fetching

    /// Downloads and parses one address now, e.g. to check it before saving it (Python:
    /// `probe`): the parse step gets no name or colour, and the owner of a Google secret
    /// address, so the counts are what a sync would show. `today` defaults to today in `zone`.
    public static func probe<Contents>(
        _ url: String, user: String = "", password: String = "", today: LocalDate? = nil, zone: TimeZone = .current,
        loader: any FeedLoader, parse: (Data, FeedContext) throws -> Contents
    ) async throws -> Contents {
        let url = try normalizeURL(url)
        let context = FeedContext(window: window(today: today ?? LocalDate.today(in: zone)), zone: zone,
                                  owner: owner(of: url))
        let body = try await download(url, user: user, password: password, loader: loader)
        do {
            return try parse(body, context)
        } catch {
            throw FeedError.notICalendar
        }
    }

    /// The events around `today` and all open to-dos of every feed, in memory (Python:
    /// `fetch`). Feeds are read in order, each with its name and colour (`colours`).
    ///
    /// One feed failing fails the whole fetch with that feed's name in front
    /// (`FeedError.inFeed`), so the device never shows a page with one calendar silently
    /// missing. No feeds at all: `FeedError.noFeeds`. Whatever `parse` throws counts as
    /// "not iCalendar"; a `FeedSecretStore` error passes through as it is, and so does
    /// cancellation.
    public static func fetch<Contents: FeedContents>(
        _ feeds: [Feed], today: LocalDate, zone: TimeZone, now: OffsetDateTime,
        secrets: any FeedSecretStore, loader: any FeedLoader, parse: (Data, FeedContext) throws -> Contents
    ) async throws -> AgendaData {
        if feeds.isEmpty { throw FeedError.noFeeds }
        let window = window(today: today)
        let hexes = colours(feeds)
        var data = AgendaData(fetchedAt: now)
        for feed in feeds {
            guard let secret = try secrets.get(feed.id), !secret.url.isEmpty else {
                throw FeedError.inFeed(name: feed.name, .missingAddress)
            }
            let context = FeedContext(window: window, zone: zone, name: feed.name, color: hexes[feed.id] ?? "",
                                      owner: owner(of: secret.url))
            let contents: Contents
            do {
                let body = try await download(secret.url, user: secret.user, password: secret.password, loader: loader)
                do {
                    contents = try parse(body, context)
                } catch {
                    throw FeedError.notICalendar
                }
            } catch let error as FeedError {
                throw FeedError.inFeed(name: feed.name, error)
            }
            data.events += contents.events
            data.tasks += contents.tasks
        }
        return data
    }

    /// `probe` with the iCal parser (`ICal.parse`): the feed's events and open to-dos, with its own
    /// name (X-WR-CALNAME) to suggest.
    public static func probe(_ url: String, user: String = "", password: String = "", today: LocalDate? = nil,
                             zone: TimeZone = .current, loader: any FeedLoader) async throws -> ParsedFeed {
        try await probe(url, user: user, password: password, today: today, zone: zone, loader: loader,
                        parse: ICal.parse)
    }

    /// `fetch` with the iCal parser (`ICal.parse`), as Python's `fetch` reads every feed.
    public static func fetch(_ feeds: [Feed], today: LocalDate, zone: TimeZone, now: OffsetDateTime,
                             secrets: any FeedSecretStore, loader: any FeedLoader) async throws -> AgendaData {
        try await fetch(feeds, today: today, zone: zone, now: now, secrets: secrets, loader: loader,
                        parse: ICal.parse)
    }

    /// `loader.load`, with any error but a `FeedError` or cancellation turned into "cannot
    /// connect to <host>", so that no error a loader throws can carry the address.
    private static func download(_ url: String, user: String, password: String,
                                 loader: any FeedLoader) async throws -> Data {
        do {
            return try await loader.load(url, user: user, password: password)
        } catch let error as FeedError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw FeedError.cannotConnect(host: host(of: url), reason: URLSessionFeedLoader.name(of: error.code))
        } catch {
            throw FeedError.cannotConnect(host: host(of: url), reason: String(describing: type(of: error)))
        }
    }
}

/// The days a fetch reads: [first, last), local midnights in the page's zone.
public struct FeedWindow: Hashable, Sendable {
    public var first: LocalDate
    /// Exclusive.
    public var last: LocalDate

    public init(first: LocalDate, last: LocalDate) {
        self.first = first
        self.last = last
    }
}

/// What the parse step of one feed is given besides the bytes: Python's arguments to
/// `ical.parse` (the window, the page's zone, the feed's name and colour, the owner).
public struct FeedContext: Hashable, Sendable {
    public var window: FeedWindow
    /// The zone the pages are drawn in: all-day dates and due dates are read in it.
    public var zone: TimeZone
    /// Put on every event and to-do; "" when probing (the calendar's own name may be used).
    public var name: String
    /// "#rrggbb", put on every event; "" when probing.
    public var color: String
    /// The address owner's e-mail (`Feeds.owner(of:)`): events they declined are left out.
    public var owner: String

    public init(window: FeedWindow, zone: TimeZone, name: String = "", color: String = "", owner: String = "") {
        self.window = window
        self.zone = zone
        self.name = name
        self.color = color
        self.owner = owner
    }

    /// The window's first midnight in `zone` (Python: `datetime.combine(first, time(), tz)`).
    public var start: Date { window.first.midnight(in: zone) }
    /// The window's end, exclusive: its last midnight in `zone`.
    public var end: Date { window.last.midnight(in: zone) }
}

/// What a parse step gives back for one feed: its events and open to-dos.
public protocol FeedContents {
    var events: [Event] { get }
    var tasks: [AgendaTask] { get }
}
