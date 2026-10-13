import Foundation
import PaperhueAgenda
import UlaniKit

/// Feeds and notes -> pages -> device (python/src/ulani_epaper/sync.py; shared/AGENDA.md 1,
/// shared/BOARD.md "Settings and sync").
///
/// Everything fetched or drawn stays in memory: nothing from the feeds is kept anywhere. The
/// board pages are drawn from the owner's saved notes and need no network. Whether a page needs
/// sending is decided by the device (a page that already holds the same image is skipped by
/// the upload probe), so there is no local state either. The pages are the panel's 7 colours
/// by construction, so each drawing becomes its frame as it is, without dither.
///
/// Editing never touches the device: the app draws pages here and pushes them when the user
/// pushes (all pages, or one). `sync` is 立即同步 and the scheduled sync: the calendar pages only.
public struct PageSync: Sendable {
    /// Uploads `[page: frame]` in one connection, the page on screen last, without switching
    /// the display (Python: `push.push_frames`).
    public typealias Push = @Sendable (_ frames: [Int: Frame],
                                       _ progress: (@Sendable (PushEvent) -> Void)?) async throws -> [Int: UploadResult]

    /// Read when no calendar source is set up: Google's public Taiwan holidays calendar (public
    /// data, no login; Python: `feeds.DEFAULT_CALENDAR_URL`).
    public static let defaultCalendarURL =
        "https://calendar.google.com/calendar/ical/zh-tw.taiwan%23holiday%40group.v.calendar.google.com/public/basic.ics"
    /// The default calendar's name on the pages and in errors (Python: `DEFAULT_CALENDAR_NAME`).
    public static let defaultCalendarName = "台灣假日"

    public let notes: NoteStore
    /// The calendar pages' background photos (nil: none can be read; pages are drawn on white).
    public let backgrounds: BackgroundStore?
    /// The saved cards (nil: none; card pages are not drawn).
    public let cards: CardStore?
    public let secrets: any FeedSecretStore
    public let loader: any FeedLoader
    /// The zone the pages are drawn in.
    public let zone: TimeZone
    /// The clock: the day drawn and the fetch time.
    public let now: @Sendable () -> Date

    public init(notes: NoteStore, backgrounds: BackgroundStore? = nil, cards: CardStore? = nil,
                secrets: any FeedSecretStore = KeychainFeedSecrets(),
                loader: any FeedLoader = URLSessionFeedLoader(), zone: TimeZone = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.notes = notes
        self.backgrounds = backgrounds
        self.cards = cards
        self.secrets = secrets
        self.loader = loader
        self.zone = zone
        self.now = now
    }

    /// Fetches the feeds and draws the calendar pages among `pages` (month, agenda, to-do, day,
    /// month grid), each on its photo in `backgrounds` (dithered at `strength`); nothing is
    /// fetched when there are none. With no feeds at all the public Taiwan holidays calendar is
    /// read instead. One failing feed fails it all (`FeedError`); a background that cannot be
    /// read leaves its page on white (`CalendarDrawing.unreadableBackgrounds`).
    public func drawCalendar(_ pages: [Int: PageKind], feeds: [Feed], backgrounds: [Int: PageBackground] = [:],
                             strength: Double = 1) async throws -> CalendarDrawing {
        let pages = pages.filter(\.value.isCalendar)
        guard !pages.isEmpty else { return CalendarDrawing() }
        let instant = now()
        let today = LocalDate(instant, in: zone)
        var feeds = feeds, secrets = self.secrets
        if feeds.isEmpty {  // read like any feed; it has no secret address, so nothing is looked up
            feeds = [Feed(id: "default", name: Self.defaultCalendarName, color: "black")]
            secrets = MemoryFeedSecrets(["default": FeedSecret(url: Self.defaultCalendarURL)])
        }
        let data = try await Feeds.fetch(feeds, today: today, zone: zone, now: OffsetDateTime(instant, in: zone),
                                         secrets: secrets, loader: loader)
        var photos: [Int: Frame] = [:], unreadable: [Int] = []
        for (page, background) in backgrounds where pages[page] != nil {
            if let frame = try? self.backgrounds?.frame(background, strength: strength) {
                photos[page] = frame
            } else {
                unreadable.append(page)  // one lost photo must not stop the sync: drawn on white
            }
        }
        let frames = try draw(pages, data: data, today: today, notes: [], backgrounds: photos)
        return CalendarDrawing(frames: frames, events: data.events.count, tasks: data.tasks.count,
                               unreadableBackgrounds: unreadable.sorted())
    }

    /// Draws the board pages among `pages` (留言板, 大字留言) from the saved notes; no network.
    /// `NoteError` when the notes cannot be read.
    public func drawBoards(_ pages: [Int: PageKind]) throws -> [Int: Frame] {
        let pages = pages.filter(\.value.isBoard)
        guard !pages.isEmpty else { return [:] }
        return try draw(pages, data: AgendaData(), today: LocalDate(now(), in: zone), notes: notes.load())
    }

    /// Draws the card pages among `pages` that have a card in `choice` (Python: push_all's card
    /// part), a photo background dithered at `strength`. A card no longer saved leaves its page
    /// out (as it is on the device); so does a card whose photo cannot be read (listed in
    /// `unreadable`; Python's render_card raises). `CardError` when the cards file cannot be read.
    public func drawCards(_ pages: [Int: PageKind], choice: [Int: String],
                          strength: Double = 1) throws -> (frames: [Int: Frame], unreadable: [Int]) {
        let chosen = choice.filter { pages[$0.key] == .card }
        guard !chosen.isEmpty, let cards else { return ([:], []) }
        let saved = Dictionary(try cards.load().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var frames: [Int: Frame] = [:], unreadable: [Int] = []
        for (page, id) in chosen {
            guard let card = saved[id] else { continue }  // deleted: the page stays as it is
            let background: Frame?
            do {
                background = try cards.background(of: card, strength: strength)
            } catch {
                unreadable.append(page)
                continue
            }
            frames[page] = try Frame(indices: CardPages.card(card, background: background).indices)
        }
        return (frames, unreadable.sorted())
    }

    /// 立即同步 and the scheduled sync: fetches the feeds, draws the calendar pages and pushes
    /// them with `push`, without switching the display. Throws before pushing anything if
    /// fetching or drawing fails, so the device never gets half an update. `drawn` gets the
    /// frames before the push starts.
    public func sync(_ settings: PageSettings, push: Push, progress: (@Sendable (PushEvent) -> Void)? = nil,
                     drawn: (@Sendable ([Int: Frame]) -> Void)? = nil) async throws -> SyncReport {
        let drawing = try await drawCalendar(settings.pages, feeds: settings.feeds, backgrounds: settings.backgrounds,
                                             strength: settings.grain)
        guard !drawing.frames.isEmpty else { return SyncReport() }
        drawn?(drawing.frames)
        let results = try await push(drawing.frames, progress)
        return SyncReport(pages: settings.pages.filter(\.value.isCalendar), events: drawing.events,
                          tasks: drawing.tasks, results: results)
    }

    private func draw(_ pages: [Int: PageKind], data: AgendaData, today: LocalDate, notes: [Note],
                      backgrounds: [Int: Frame] = [:]) throws -> [Int: Frame] {
        try Dictionary(uniqueKeysWithValues: pages.map { number, kind in
            let bg = backgrounds[number]
            let page = switch kind {
            case .month: CalendarPages.month(data, today: today, zone: zone, background: bg)
            case .agenda: CalendarPages.agenda(data, today: today, zone: zone, background: bg)
            case .todo: CalendarPages.todo(data, today: today, zone: zone, background: bg)
            case .day: CalendarPages.day(data, today: today, zone: zone, background: bg)
            case .monthgrid: CalendarPages.monthGrid(data, today: today, zone: zone, background: bg)
            case .board: BoardPages.board(notes, zone: zone)
            case .message: BoardPages.message(notes, zone: zone)
            case .photo, .card: preconditionFailure("photo and card pages are not drawn here")
            }
            return (number, try Frame(indices: page.indices))
        })
    }
}

/// The calendar pages as drawn, and how much the feeds gave (counts only: no calendar content).
public struct CalendarDrawing: Equatable, Sendable {
    public var frames: [Int: Frame] = [:]
    public var events = 0
    public var tasks = 0
    /// Pages whose background photo could not be read: drawn on white.
    public var unreadableBackgrounds: [Int] = []
}

/// What a sync did (Python: `SyncReport`). Only counts and outcomes: no calendar content.
public struct SyncReport: Equatable, Sendable {
    /// Page -> the kind drawn and pushed.
    public var pages: [Int: PageKind] = [:]
    /// Events and open to-dos fetched.
    public var events = 0
    public var tasks = 0
    /// What the device did with each page.
    public var results: [Int: UploadResult] = [:]
}
