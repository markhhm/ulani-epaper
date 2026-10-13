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
    case card(CardError)
    case other(String)

    public init(_ error: any Error) {
        switch error {
        case let error as FeedError: self = .feed(error)
        case let error as NoteError: self = .note(error)
        case let error as CardError: self = .card(error)
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
        if !kind.isCalendar { cancelBackgroundTask(model) }  // a background preview no longer applies
        model.kind = kind
        model.drawing = nil
        model.setProgress(kind == .photo && model.preview != nil ? .previewReady : .blank, 0)
        settings.pages[page] = kind
        if kind != .card { settings.cardChoice[page] = nil }  // only card pages keep a card
        saveSettings()
        if kind.isBoard { redrawBoards() }
        if kind.isCalendar { showBackground(model) }
        if kind.isCard { showCards() }
    }

    /// The text on a tile's preview while it has no picture.
    public func tileText(_ page: PageModel) -> String {
        switch page.kind {
        case .photo: strings[page.failed ? .unreadable : .noPhoto]
        case .board, .message: notesProblem == nil ? "" : strings[.notesUnreadableTile]
        case .card: strings.cardPlaceholder()
        case .month, .agenda, .todo, .day, .monthgrid: strings.calendarPlaceholder(page.kind)
        }
    }

    /// The line under a tile's preview: the photo's name, or where the page comes from.
    public func nameText(_ page: PageModel) -> String {
        switch page.kind {
        case .photo: page.name ?? ""
        case .board, .message: strings.boardTileName(page.kind)
        case .card: chosenCard(for: page.page) == nil ? strings.cardTileName() : strings.pageKind(.card)
        case .month, .agenda, .todo, .day, .monthgrid: strings.calendarTileName(page.kind)
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

    /// The user name kept with `feed`'s address ("" when none), for the edit form.
    public func user(of feed: Feed) -> String {
        (try? pageSync.secrets.get(feed.id)).flatMap { $0 }?.user ?? ""
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
            forgetCalendarDrawings()
            return .success((feed.name, parsed.events.count, parsed.tasks.count))
        } catch {
            return .failure(Problem(error))
        }
    }

    /// 編輯…: renames or recolours `feed`, and with a new address (or user name / password; empty
    /// keeps them) reads it once to check it before keeping it (Python: FeedDialog.save). The
    /// old password is reused only for an address on the same host. The counts are nil when
    /// nothing was read (only the name or colour changed).
    public func editFeed(_ feed: Feed, name: String, url: String, user: String, password: String,
                         color: String) async -> Result<(name: String, events: Int?, tasks: Int?), Problem> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.feed(.unnamedFeed)) }
        do {
            let old = try pageSync.secrets.get(feed.id)
            if old == nil && url.isEmpty { return .failure(.feed(.missingAddress)) }  // lost: a new one is needed
            var counts: (Int, Int)?
            if !url.isEmpty || !password.isEmpty || user != (old?.user ?? "") {
                let target = try Feeds.normalizeURL(url.isEmpty ? old?.url ?? "" : url)
                let kept = Feeds.login(keptFrom: old, for: target)  // another host: the old password is not reused
                let password = password.isEmpty && user == kept.user ? kept.password : password
                let parsed = try await Feeds.probe(target, user: user, password: password, zone: pageSync.zone,
                                                   loader: pageSync.loader)
                // Removed meanwhile: its address must not come back into the Keychain.
                guard settings.feeds.contains(where: { $0.id == feed.id }) else { return .failure(.feed(.missingAddress)) }
                try pageSync.secrets.set(FeedSecret(url: target, user: user, password: password), for: feed.id)
                counts = (parsed.events.count, parsed.tasks.count)
            }
            guard let index = settings.feeds.firstIndex(where: { $0.id == feed.id }) else { return .failure(.feed(.missingAddress)) }
            var feeds = settings.feeds
            feeds[index].name = name
            feeds[index].color = color
            try Feed.validate(feeds)
            settings.feeds = feeds
            saveSettings()
            forgetCalendarDrawings()
            return .success((name, counts?.0, counts?.1))
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
            forgetCalendarDrawings()
            return nil
        } catch {
            return Problem(error)
        }
    }

    /// The sources changed: the calendar previews no longer show what a push would send.
    private func forgetCalendarDrawings() {
        for page in pages where page.kind.isCalendar {
            page.drawing = nil
        }
    }

    // MARK: dropped photos

    /// Photos dropped on the window: one per photo page in page order; `convert` first turns
    /// the pages `dropConversion` names into photo pages. Returns how many were loaded.
    @discardableResult
    public func loadDropped(_ urls: [URL], convert: Bool) -> Int {
        guard canEdit else { return 0 }
        let urls = Array(urls.prefix(Panel.userSlots.count))
        if convert {
            for page in dropConversion(count: urls.count) { setKind(.photo, for: page.page) }
        }
        let photoPages = pages.filter { $0.kind == .photo }
        for (page, url) in zip(photoPages, urls) {
            load(.file(url), into: page.page)
        }
        let loaded = min(urls.count, photoPages.count)
        partialDrop = loaded < urls.count ? loaded : nil
        return loaded
    }

    /// The pages that would become photo pages for `count` dropped photos: the first pages that
    /// are not photo pages, as many as photos are missing a page (Python: App.load_dropped).
    public func dropConversion(count: Int) -> [(page: Int, kind: PageKind)] {
        let photoPages = pages.filter { $0.kind == .photo }.count
        let missing = min(count, Panel.userSlots.count) - photoPages
        guard missing > 0 else { return [] }
        return pages.filter { $0.kind != .photo }.prefix(missing).map { ($0.page, $0.kind) }
    }

    // MARK: calendar backgrounds (底圖, shared/LAYOUTS.md 12)

    /// Whether calendar page `page` sits on a photo.
    public func hasBackground(_ page: PageModel) -> Bool { settings.backgrounds[page.page] != nil }

    /// 選擇底圖照片…: keeps an upright copy (at most 4K) of the photo from `source` behind
    /// calendar page `page`, centred; the tile shows it as the panel will until the next push or
    /// sync draws the calendar on it. Nothing reaches the device now. A newer choice, a removal
    /// or another page kind supersedes it: its file is dropped and nothing changes.
    public func setBackground(_ source: PhotoSource, for page: Int) {
        guard canEdit, Panel.userSlots.contains(page), let store = pageSync.backgrounds else { return }
        let model = self.page(page)
        cancelBackgroundTask(model)
        model.isLoadingBackground = true
        model.isSettingBackground = true
        model.setProgress(.rendering, 0)
        let generation = model.backgroundGeneration
        model.backgroundTask = Task { [weak self, weak model] in
            let result = await Task.detached(priority: .userInitiated) { () async throws -> URL in
                try store.prepare(try await source.fetch().decode().image)
            }.result
            guard let self, let model, model.backgroundGeneration == generation else {
                if case .success(let prepared) = result { store.discard(prepared) }
                return
            }
            model.isLoadingBackground = false
            model.isSettingBackground = false
            do {
                self.settings.backgrounds[page] = try store.install(try result.get(), page: page)
                self.saveSettings()
                model.setProgress(.backgroundSet, 0)
                self.showBackground(model)
            } catch {
                if case .success(let prepared) = result { store.discard(prepared) }
                model.setProgress(.previewFailed(name: source.name, reason: PreviewFailure(error)), 0)
            }
        }
    }

    /// 移除底圖: the page is drawn on white again (from the next push or sync).
    public func clearBackground(page: Int) {
        guard canEdit, Panel.userSlots.contains(page), let background = settings.backgrounds[page] else { return }
        let model = self.page(page)
        cancelBackgroundTask(model)
        pageSync.backgrounds?.remove(background)
        settings.backgrounds[page] = nil
        saveSettings()
        model.drawing = nil
        model.setProgress(.backgroundCleared, 0)
    }

    /// 調整底圖範圍…: the kept photo and its crop for the crop editor; nil without a background.
    public func backgroundCropEditing(for page: Int) -> CropEditing? {
        guard canEdit, Panel.userSlots.contains(page), let background = settings.backgrounds[page],
              let photo = try? pageSync.backgrounds?.photo(background) else { return nil }
        return CropEditing(page: page, image: photo.image, geometry: CropGeometry(photo: photo.size, crop: background.crop),
                           background: true)
    }

    /// The crop editor's 確定 for a background (nil: centred), checked against the kept photo.
    public func setBackgroundCrop(_ crop: Crop?, for page: Int) {
        guard canEdit, Panel.userSlots.contains(page), var background = settings.backgrounds[page],
              let photo = try? pageSync.backgrounds?.photo(background) else { return }
        if let crop, (try? crop.validated(width: photo.size.width, height: photo.size.height)) == nil { return }
        background.crop = crop
        settings.backgrounds[page] = background
        saveSettings()
        showBackground(self.page(page))
    }

    /// A calendar tile with a background shows the photo as the panel will (until a push or
    /// sync draws the calendar on it), dithered off the main actor at the grain setting. A
    /// photo being chosen shows itself when kept.
    func showBackground(_ model: PageModel) {
        guard model.kind.isCalendar, !model.isSettingBackground, let background = settings.backgrounds[model.page],
              let store = pageSync.backgrounds else { return }
        cancelBackgroundTask(model)
        let strength = settings.grain, generation = model.backgroundGeneration
        model.isLoadingBackground = true
        model.backgroundTask = Task { [weak model] in
            let frame = await Task.detached(priority: .userInitiated) {
                try? store.frame(background, strength: strength)
            }.value
            guard let model, model.backgroundGeneration == generation else { return }
            model.isLoadingBackground = false
            model.drawing = frame?.previewImage()
        }
    }

    func redrawBackgrounds() {
        for page in pages where page.kind.isCalendar { showBackground(page) }
    }

    /// Supersedes the page's background task (its result is dropped).
    func cancelBackgroundTask(_ model: PageModel) {
        model.backgroundGeneration += 1
        model.backgroundTask?.cancel()
        model.backgroundTask = nil
        model.isLoadingBackground = false
        model.isSettingBackground = false
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
        if settings.schedule.isEmpty {  // turned on now; an edit keeps a due time due
            ScheduledSync.startChecking(defaults: defaults, now: pageSync.now())
        }
        settings.schedule = times
        saveSettings()
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

    /// The last sync's outcome (立即同步 or a scheduled one), if any.
    public var lastSync: ScheduledSync.Outcome? { ScheduledSync.lastOutcome(defaults: defaults) }
}

extension NoteStore {
    /// Application Support/Paperhue/notes.json (inside the app's sandbox container, which the
    /// scheduled sync shares).
    public static var app: NoteStore {
        NoteStore(url: URL.applicationSupportDirectory.appendingPathComponent("Paperhue/notes.json"))
    }
}

extension PageSync {
    /// The app's: its notes, cards and background photos (as Python keeps them: cards.json and
    /// backgrounds/ in one folder), the Keychain, the network, this Mac's zone and clock.
    public static var app: PageSync {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("Paperhue")
        return PageSync(notes: .app, backgrounds: BackgroundStore(folder: folder.appendingPathComponent("backgrounds")),
                        cards: CardStore(folder: folder))
    }
}
