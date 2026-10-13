import CoreGraphics
import Foundation
import PaperhueAgenda
import PaperhuePages
import UlaniKit

/// An error the app words in the interface language: calendar sources and notes errors carry
/// both languages; any other error shows its technical message.
public enum Problem: Error, Sendable, Equatable {
    case feed(FeedError)
    case note(NoteError)
    case other(String)

    public init(_ error: any Error) {
        switch error {
        case let error as FeedError: self = .feed(error)
        case let error as NoteError: self = .note(error)
        default: self = .other(String(describing: error))
        }
    }
}

/// What each page shows, the notes and the calendar sources (Python: App.set_kind,
/// NotesDialog, FeedsDialog). Every change is saved at once and redraws the previews; none
/// touches the device.
extension PushViewModel {
    // MARK: page kinds

    /// Show `kind` on `page` from now on and keep the choice (not during a job). A photo page
    /// keeps its photo while it shows something else.
    public func setKind(_ kind: PageKind, for page: Int) {
        guard canEdit, Panel.userSlots.contains(page) else { return }
        let model = self.page(page)
        guard kind != model.kind else { return }
        model.kind = kind
        model.drawing = nil
        model.setProgress(kind == .photo && model.preview != nil ? .previewReady : .blank, 0)
        settings.pages[page] = kind
        saveSettings()
        if kind.isBoard { redrawBoards() }
    }

    /// The text on a tile's preview while it has no picture.
    public func tileText(_ page: PageModel) -> String {
        switch page.kind {
        case .photo: strings[page.failed ? .unreadable : .noPhoto]
        case .board, .message: notesProblem == nil ? "" : strings[.notesUnreadableTile]
        case .month, .agenda, .todo: strings.calendarPlaceholder(page.kind)
        }
    }

    /// The line under a tile's preview: the photo's name, or where the page comes from.
    public func nameText(_ page: PageModel) -> String {
        switch page.kind {
        case .photo: page.name ?? ""
        case .board, .message: strings.boardTileName(page.kind)
        case .month, .agenda, .todo: strings.calendarTileName(page.kind)
        }
    }

    /// Keeps `settings` (they are checked when changed, so this does not fail).
    func saveSettings() {
        try? settings.save(to: defaults)
    }

    /// Read the saved notes again and redraw the board pages' previews.
    func redrawBoards() {
        do {
            notes = try pageSync.notes.load()
            notesProblem = nil
        } catch {
            notes = []
            notesProblem = Problem(error)
        }
        let boards = pages.filter(\.kind.isBoard)
        let drawn = notesProblem == nil
            ? (try? pageSync.drawBoards(Dictionary(uniqueKeysWithValues: boards.map { ($0.page, $0.kind) }))) : nil
        for page in boards {
            page.drawing = drawn?[page.page]?.previewImage()
        }
    }

    // MARK: notes (留言)

    /// Whether some page is a board page (else 留言 says how to make one).
    public var hasBoardPage: Bool { pages.contains { $0.kind.isBoard } }

    /// Saves a new note on top and redraws the board previews; nil, or why it was not saved.
    public func addNote(_ text: String, color: String) -> Problem? {
        noteChange { _ = try pageSync.notes.add(text, color: color) }
    }

    public func removeNote(id: String) -> Problem? {
        noteChange { _ = try pageSync.notes.remove(id) }
    }

    public func clearNotes() -> Problem? {
        noteChange { _ = try pageSync.notes.clear() }
    }

    private func noteChange(_ change: () throws -> Void) -> Problem? {
        guard canEdit else { return nil }
        defer { redrawBoards() }
        do {
            try change()
            return nil
        } catch {
            return Problem(error)
        }
    }

    // MARK: calendar sources (行事曆來源)

    /// The host of `feed`'s address (never the address, a password), or nil when none is kept.
    public func host(of feed: Feed) -> String? {
        (try? pageSync.secrets.get(feed.id)).flatMap { $0 }.map { Feeds.host(of: $0.url) }
    }

    /// 檢查並加入: reads the address once to check it (nothing from it is kept), then keeps
    /// the source; an empty name takes the calendar's own. The counts are what a sync shows.
    public func addFeed(name: String, url: String, user: String, password: String,
                        color: String) async -> Result<(name: String, events: Int, tasks: Int), Problem> {
        do {
            let parsed = try await Feeds.probe(url, user: user, password: password, zone: pageSync.zone,
                                               loader: pageSync.loader)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            var feeds = settings.feeds
            let feed = try Feeds.add(name: trimmed.isEmpty ? parsed.name : trimmed, url: url, color: color,
                                     user: user, password: password, to: &feeds, secrets: pageSync.secrets)
            settings.feeds = feeds
            saveSettings()
            return .success((feed.name, parsed.events.count, parsed.tasks.count))
        } catch {
            return .failure(Problem(error))
        }
    }

    public func removeFeed(_ feed: Feed) -> Problem? {
        do {
            var feeds = settings.feeds
            try Feeds.remove(feed, from: &feeds, secrets: pageSync.secrets)
            settings.feeds = feeds
            saveSettings()
            return nil
        } catch {
            return Problem(error)
        }
    }

    // MARK: daily sync (每日排程)

    /// 啟用／更新排程: keeps `times` ("HH:MM") and lets the background agent sync at them.
    /// Times already past today wait for tomorrow.
    public func setSchedule(_ times: [String]) -> Problem? {
        let times = Array(Set(times)).sorted()
        guard !times.isEmpty, times.allSatisfy({ PageSettings.minutes($0) != nil }) else { return nil }
        do {
            try agent.register()
        } catch {
            return Problem(error)
        }
        settings.schedule = times
        saveSettings()
        ScheduledSync.startChecking(defaults: defaults, now: pageSync.now())
        return nil
    }

    /// 停用排程.
    public func turnScheduleOff() -> Problem? {
        settings.schedule = []
        saveSettings()
        do {
            try agent.unregister()
            return nil
        } catch {
            return Problem(error)
        }
    }

    /// The user must still allow the agent in System Settings › General › Login Items.
    public var scheduleNeedsApproval: Bool { !settings.schedule.isEmpty && agent.needsApproval }

    /// The last scheduled sync's outcome, if any.
    public var lastScheduledSync: ScheduledSync.Outcome? { ScheduledSync.lastOutcome(defaults: defaults) }
}

extension NoteStore {
    /// Application Support/Paperhue/notes.json (inside the app's sandbox container, which the
    /// scheduled sync shares).
    public static var app: NoteStore {
        NoteStore(url: URL.applicationSupportDirectory.appendingPathComponent("Paperhue/notes.json"))
    }
}

extension PageSync {
    /// The app's: its notes, the Keychain, the network, this Mac's zone and clock.
    public static var app: PageSync { PageSync(notes: .app) }
}
