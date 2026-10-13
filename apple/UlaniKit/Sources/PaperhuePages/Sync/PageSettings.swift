import Foundation
import PaperhueAgenda
import UlaniKit

/// What a page shows (python/src/ulani_epaper/config.py, `PAGE_KINDS`). Sync leaves photo pages
/// alone and draws every other kind.
public enum PageKind: String, CaseIterable, Sendable {
    case photo, month, agenda, todo, day, monthgrid, board, message, card

    /// Drawn from the calendar feeds (Python: `CALENDAR_KINDS`).
    public var isCalendar: Bool { [.month, .agenda, .todo, .day, .monthgrid].contains(self) }
    /// Drawn from the notes, no network needed (Python: `BOARD_KINDS`).
    public var isBoard: Bool { self == .board || self == .message }
    /// Shows a saved card, sent by a push; a sync never redraws it (Python: `CARD_KINDS`).
    public var isCard: Bool { self == .card }
}

/// What each page shows, the calendar sources and the daily sync times (python/src/ulani_epaper/
/// config.py, `Settings`; shared/AGENDA.md 4.1), kept in UserDefaults. No calendar content, and
/// no address: a feed's address is a secret in a `FeedSecretStore` under its id. The Apple app
/// finds the device itself and keeps its language apart, so there is no device address or
/// language here.
public struct PageSettings: Hashable, Sendable {
    /// Python: `DEFAULT_PAGES`.
    public static let defaultPages: [Int: PageKind] = [1: .month, 2: .agenda, 3: .todo, 4: .photo]
    /// The UserDefaults key: the settings as JSON in the shape of Python's settings.json,
    /// {"pages": {"1": "month", ...}, "feeds": [{"id": ..., "name": ..., "color": ...}],
    /// "schedule": ["07:00", ...], "backgrounds": {"1": {"image": "page-1.jpg", "crop": null}},
    /// "grain": 1.0}.
    public static let defaultsKey = "pageSettings"

    /// Page (1-4) -> what it shows.
    public var pages: [Int: PageKind]
    /// The calendar sources, in display order.
    public var feeds: [Feed]
    /// The daily sync times, "HH:MM" (24-hour), ascending; empty: no scheduled sync (the default).
    public var schedule: [String]
    /// Page (1-4) -> the photo its calendar page is drawn on.
    public var backgrounds: [Int: PageBackground]
    /// The grain setting: the share of the dithering error spread (1 = full Stucki), for photos,
    /// and for backgrounds also in the scheduled sync.
    public var grain: Double
    /// Card page (1-4) -> the id of the card chosen for it, sent by the next push (Python:
    /// `card_choice`). Only card pages keep one.
    public var cardChoice: [Int: String]

    public init(pages: [Int: PageKind] = PageSettings.defaultPages, feeds: [Feed] = [], schedule: [String] = [],
                backgrounds: [Int: PageBackground] = [:], grain: Double = 1, cardChoice: [Int: String] = [:]) {
        self.pages = pages
        self.feeds = feeds
        self.schedule = schedule
        self.backgrounds = backgrounds
        self.grain = grain
        self.cardChoice = cardChoice.filter { pages[$0.key] == .card }
    }

    /// The card pages, in page order (Python: `card_page_slots`).
    public var cardPages: [Int] { pages.filter(\.value.isCard).keys.sorted() }

    /// Python: `Settings.validate` for pages and feeds. Throws `PageSettingsError` or the
    /// feeds' `FeedError`.
    public func validate() throws {
        if let page = pages.keys.sorted().first(where: { !(1...4).contains($0) }) {
            throw PageSettingsError.pageOutOfRange(page)
        }
        try Feed.validate(feeds)
        if let time = schedule.first(where: { Self.minutes($0) == nil }) {
            throw PageSettingsError.invalidTime(time)
        }
        if let page = backgrounds.keys.sorted().first(where: { !(1...4).contains($0) || !backgrounds[$0]!.isValid }) {
            throw PageSettingsError.invalidBackground(page)
        }
        guard grain > 0 && grain <= 1 else { throw PageSettingsError.unreadable }  // Python: 0 < grain <= 1
    }

    /// Minutes after midnight of an "HH:MM" time (00:00-23:59), else nil.
    public static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return hour * 60 + minute
    }

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
        var backgrounds: [Int: PageBackground] = [:]
        for (key, bg) in kept.backgrounds ?? [:] {
            guard let page = Int(key), bg.crop.map({ $0.count == 4 }) ?? true else { throw PageSettingsError.unreadable }
            backgrounds[page] = PageBackground(image: bg.image, crop: bg.crop.map {
                Crop(left: $0[0], top: $0[1], width: $0[2], height: $0[3])
            })
        }
        var cardChoice: [Int: String] = [:]
        for (key, id) in kept.card_choice ?? [:] {
            guard let page = Int(key), (1...4).contains(page) else { throw PageSettingsError.unreadable }
            cardChoice[page] = id
        }
        let settings = PageSettings(pages: pages, feeds: kept.feeds ?? [], schedule: kept.schedule ?? [],
                                    backgrounds: backgrounds, grain: kept.grain ?? 1, cardChoice: cardChoice)
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
                        feeds: feeds, schedule: schedule,
                        backgrounds: Dictionary(uniqueKeysWithValues: backgrounds.map { page, bg in
                            (String(page), KeptBackground(image: bg.image,
                                                          crop: bg.crop.map { [$0.left, $0.top, $0.width, $0.height] }))
                        }), grain: grain,
                        card_choice: Dictionary(uniqueKeysWithValues: cardChoice.filter { pages[$0.key] == .card }
                            .map { (String($0.key), $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        defaults.set(try encoder.encode(kept), forKey: Self.defaultsKey)
    }

    /// The kept form.
    private struct Kept: Codable {
        var pages: [String: String]?
        var feeds: [Feed]?
        var schedule: [String]?
        var backgrounds: [String: KeptBackground]?
        var grain: Double?
        var card_choice: [String: String]?  // Python's key
    }

    private struct KeptBackground: Codable {
        var image: String
        var crop: [Double]?
    }
}

/// Why page settings cannot be kept or read. Feed problems are the feeds' `FeedError`.
public enum PageSettingsError: Error, Equatable, Sendable {
    /// Pages are 1-4.
    case pageOutOfRange(Int)
    /// The kept settings are not in this form, or not valid (e.g. an unknown page kind).
    case unreadable
    /// A daily sync time that is not "HH:MM" (00:00-23:59).
    case invalidTime(String)
    /// A background is for pages 1-4 and names a plain .jpg or .png file.
    case invalidBackground(Int)
}
