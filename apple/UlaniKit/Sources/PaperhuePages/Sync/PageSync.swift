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
public struct PageSync: Sendable {
    /// Uploads `[page: frame]` in one connection, the page on screen last, and with `show`
    /// (1-4) also switches the display to that page (`CalendarSession.push(_:show:progress:)`;
    /// Python: `push.push_frames`).
    public typealias Push = @Sendable (_ frames: [Int: Frame], _ show: Int?,
                                       _ progress: (@Sendable (PushEvent) -> Void)?) async throws -> [Int: UploadResult]

    /// The page `post` switches the display to (Python: `show_target`).
    public enum Show: String, CaseIterable, Sendable {
        /// The first 大字留言 page, else the first 留言板 page.
        case auto
        /// The first 留言板 page (the `auto` choice when there is none).
        case board
        /// The first 大字留言 page (the `auto` choice when there is none).
        case message
        /// No switch.
        case none
    }

    public let notes: NoteStore
    public let push: Push
    public let secrets: any FeedSecretStore
    public let loader: any FeedLoader
    /// The zone the pages are drawn in.
    public let zone: TimeZone
    /// The clock: the sync's day and fetch time.
    public let now: @Sendable () -> Date

    public init(notes: NoteStore, push: @escaping Push, secrets: any FeedSecretStore = KeychainFeedSecrets(),
                loader: any FeedLoader = URLSessionFeedLoader(), zone: TimeZone = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.notes = notes
        self.push = push
        self.secrets = secrets
        self.loader = loader
        self.zone = zone
        self.now = now
    }

    /// One sync: draws every page that is not a photo and pushes them without switching the
    /// display. The feeds are fetched only when a calendar page (month, agenda, to-do) exists,
    /// the notes read only when a board page does. Throws before pushing anything if reading
    /// the notes, fetching (one failing feed fails it all, `FeedError`) or drawing fails, so the
    /// device never gets half an update. `drawn` gets the frames before the push starts.
    public func sync(_ settings: PageSettings, progress: (@Sendable (PushEvent) -> Void)? = nil,
                     drawn: (@Sendable ([Int: Frame]) -> Void)? = nil) async throws -> SyncReport {
        let pages = settings.drawnPages
        guard !pages.isEmpty else { return SyncReport() }
        let instant = now()
        let today = LocalDate(instant, in: zone)
        let board = settings.boardPages.isEmpty ? [] : try notes.load()
        var data = AgendaData()
        if pages.values.contains(where: \.isCalendar) {
            data = try await Feeds.fetch(settings.feeds, today: today, zone: zone, now: OffsetDateTime(instant, in: zone),
                                         secrets: secrets, loader: loader)
        }
        let frames = try draw(pages, data: data, today: today, notes: board)
        drawn?(frames)
        let results = try await push(frames, nil, progress)
        return SyncReport(pages: pages, events: data.events.count, tasks: data.tasks.count, notes: board.count,
                          results: results)
    }

    /// Draws only the message board pages (留言板, 大字留言) from the saved notes, pushes them
    /// and switches the display to the page `show` picks, all in one connection. No feed is
    /// fetched, so it works offline. `SyncError.noBoardPage` when no page is a board kind.
    public func post(_ settings: PageSettings, show: Show = .auto, progress: (@Sendable (PushEvent) -> Void)? = nil,
                     drawn: (@Sendable ([Int: Frame]) -> Void)? = nil) async throws -> SyncReport {
        let pages = settings.boardPages
        guard !pages.isEmpty else { throw SyncError.noBoardPage }
        let target = Self.target(of: show, in: pages)
        let board = try notes.load()
        let frames = try draw(pages, data: AgendaData(), today: LocalDate(now(), in: zone), notes: board)
        drawn?(frames)
        let results = try await push(frames, target, progress)
        return SyncReport(pages: pages, notes: board.count, results: results, show: target)
    }

    /// Python: `show_target`.
    static func target(of show: Show, in boardPages: [Int: PageKind]) -> Int? {
        let preferred: [PageKind]
        switch show {
        case .none: return nil
        case .auto: preferred = []
        case .board: preferred = [.board]
        case .message: preferred = [.message]
        }
        for kind in preferred + [.message, .board] {
            if let page = boardPages.filter({ $0.value == kind }).keys.min() { return page }
        }
        return nil
    }

    private func draw(_ pages: [Int: PageKind], data: AgendaData, today: LocalDate,
                      notes: [Note]) throws -> [Int: Frame] {
        try pages.mapValues { kind in
            let page = switch kind {
            case .month: CalendarPages.month(data, today: today, zone: zone)
            case .agenda: CalendarPages.agenda(data, today: today, zone: zone)
            case .todo: CalendarPages.todo(data, today: today, zone: zone)
            case .board: BoardPages.board(notes, zone: zone)
            case .message: BoardPages.message(notes, zone: zone)
            case .photo: preconditionFailure("photo pages are not drawn")
            }
            return try Frame(indices: page.indices)
        }
    }
}

/// What a sync or post did (Python: `SyncReport`). Only counts and outcomes: no calendar
/// content.
public struct SyncReport: Equatable, Sendable {
    /// Page -> the kind drawn and pushed.
    public var pages: [Int: PageKind] = [:]
    /// Events and open to-dos fetched (0 when no calendar page was drawn).
    public var events = 0
    public var tasks = 0
    /// Notes the board pages were drawn from.
    public var notes = 0
    /// What the device did with each page.
    public var results: [Int: UploadResult] = [:]
    /// The page the display was switched to (post).
    public var show: Int?
}

/// Why a post could not start.
public enum SyncError: Error, Equatable, Sendable {
    /// No page is 留言板 or 大字留言.
    case noBoardPage
}
