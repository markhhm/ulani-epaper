import Foundation
import PaperhueAgenda

/// What a page shows (python/src/ulani_epaper/config.py, `PAGE_KINDS`). Sync leaves photo pages
/// alone and draws every other kind.
public enum PageKind: String, CaseIterable, Sendable {
    case photo, month, agenda, todo, board, message

    /// Drawn from the calendar feeds (Python: `CALENDAR_KINDS`).
    public var isCalendar: Bool { self == .month || self == .agenda || self == .todo }
    /// Drawn from the notes, no network needed (Python: `BOARD_KINDS`).
    public var isBoard: Bool { self == .board || self == .message }
}

/// What each page shows and the calendar sources (python/src/ulani_epaper/config.py,
/// `Settings`; shared/AGENDA.md 4.1), kept in UserDefaults. No calendar content, and no
/// address: a feed's address is a secret in a `FeedSecretStore` under its id. The Apple app
/// syncs on demand, finds the device itself and keeps its language apart, so there are no
/// sync times, device address or language here.
public struct PageSettings: Hashable, Sendable {
    /// Python: `DEFAULT_PAGES`.
    public static let defaultPages: [Int: PageKind] = [1: .month, 2: .agenda, 3: .todo, 4: .photo]
    /// The UserDefaults key: the settings as JSON in the shape of Python's settings.json,
    /// {"pages": {"1": "month", ...}, "feeds": [{"id": ..., "name": ..., "color": ...}]}.
    public static let defaultsKey = "pageSettings"

    /// Page (1-4) -> what it shows.
    public var pages: [Int: PageKind]
    /// The calendar sources, in display order.
    public var feeds: [Feed]

    public init(pages: [Int: PageKind] = PageSettings.defaultPages, feeds: [Feed] = []) {
        self.pages = pages
        self.feeds = feeds
    }

    /// Python: `Settings.validate` for pages and feeds. Throws `PageSettingsError` or the
    /// feeds' `FeedError`.
    public func validate() throws {
        if let page = pages.keys.sorted().first(where: { !(1...4).contains($0) }) {
            throw PageSettingsError.pageOutOfRange(page)
        }
        try Feed.validate(feeds)
    }

    /// The pages a sync draws: every one that is not a photo (Python: `calendar_pages`).
    public var drawnPages: [Int: PageKind] { pages.filter { $0.value != .photo } }

    /// The message board pages, 留言板 and 大字留言 (Python: `board_pages`).
    public var boardPages: [Int: PageKind] { pages.filter { $0.value.isBoard } }

    /// The kept settings; the defaults when none are kept. Pages missing from them keep their
    /// default kind. Settings that cannot be read are `PageSettingsError.unreadable` and are
    /// left as they are.
    public static func load(from defaults: UserDefaults = .standard) throws -> PageSettings {
        guard let value = defaults.object(forKey: defaultsKey) else { return PageSettings() }
        guard let data = value as? Data, let kept = try? JSONDecoder().decode(Kept.self, from: data) else {
            throw PageSettingsError.unreadable
        }
        var pages = defaultPages
        for (key, raw) in kept.pages ?? [:] {
            guard let page = Int(key), let kind = PageKind(rawValue: raw) else { throw PageSettingsError.unreadable }
            pages[page] = kind
        }
        let settings = PageSettings(pages: pages, feeds: kept.feeds ?? [])
        do {
            try settings.validate()
        } catch {
            throw PageSettingsError.unreadable
        }
        return settings
    }

    /// Validates and keeps the settings; nothing is kept if they are not valid.
    public func save(to defaults: UserDefaults = .standard) throws {
        try validate()
        let kept = Kept(pages: Dictionary(uniqueKeysWithValues: pages.map { (String($0.key), $0.value.rawValue) }),
                        feeds: feeds)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        defaults.set(try encoder.encode(kept), forKey: Self.defaultsKey)
    }

    /// The kept form.
    private struct Kept: Codable {
        var pages: [String: String]?
        var feeds: [Feed]?
    }
}

/// Why page settings cannot be kept or read. Feed problems are the feeds' `FeedError`.
public enum PageSettingsError: Error, Equatable, Sendable {
    /// Pages are 1-4.
    case pageOutOfRange(Int)
    /// The kept settings are not in this form, or not valid (e.g. an unknown page kind).
    case unreadable
}
