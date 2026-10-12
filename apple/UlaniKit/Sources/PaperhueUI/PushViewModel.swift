import CoreGraphics
import Foundation
import Observation
import UlaniKit

/// How grainy dithered photos look: the share of each pixel's colour error that is spread to
/// its neighbours. Less spreading gives smoother areas and less vivid in-between colours.
public enum Grain: CaseIterable, Sendable, Hashable {
    case standard, soft, softer, smoothest

    public var strength: Double {
        switch self {
        case .standard: 1.0
        case .soft: 0.8
        case .softer: 0.65
        case .smoothest: 0.5
        }
    }
}

/// State and actions of the app (Python: gui.App): four pages, the fit/grain options,
/// one calendar job at a time (push, status, verify), the interface language.
///
/// Previews render off the main actor, at most two decoding at a time (fetching, e.g. an
/// iCloud download, holds no slot); a render superseded by a newer photo, a clear, an
/// option change or a new crop is dropped (`PageModel.generation`).
///
/// The model keeps state, never text: the views ask `strings` (or `summaryText`,
/// `statusText(of:)`, ...) for the text in the current language, so switching the language
/// changes every text on screen at once, also during a job.
@MainActor @Observable
public final class PushViewModel {
    public enum Job: Sendable, Equatable { case push, info, verify }

    /// The line above the push button.
    public enum Summary: Sendable, Equatable {
        case idle, pushing, pushDone(changed: Int, unchanged: Int), pushFailed
        case verifying, verifyDone(matching: [Int], differing: [Int]), verifyFailed
    }

    /// The device line at the top.
    public enum DeviceStatus: Sendable, Equatable {
        case unknown, connecting, unreachable, justPushed, status(CalendarStatus)
    }

    /// A failed job: the alert names the job, explains the error (when there is a hint)
    /// and shows its technical message.
    public struct Alert: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let job: Job
        public let hint: ErrorHint?
        /// The error's technical message (English, as UlaniKit writes it).
        public let detail: String

        public init(job: Job, error: any Error) {
            self.job = job
            hint = ErrorHint(error)
            detail = String(describing: error)
        }
    }

    /// One line of the "技術資訊" section.
    public enum LogEntry: Sendable, Equatable {
        /// A pushed page's checksums.
        case crc(page: Int, crc32: UInt32, crc16: UInt16)
        /// A job failed with this technical message.
        case failed(Job, detail: String)
        /// What verify found on a page.
        case verified(page: Int, CalendarSession.ProbeResult)
    }

    public let pages: [PageModel]
    public private(set) var fit: FitMode = .cover
    public private(set) var grain: Grain = .standard
    /// The calendar job running now, if any.
    public private(set) var job: Job?
    public private(set) var summary = Summary.idle
    public private(set) var deviceStatus = DeviceStatus.unknown
    public var alert: Alert?
    /// The "技術資訊" section, oldest first.
    public private(set) var technicalLog: [LogEntry] = []
    /// The frames of the last successful push: what `verify` probes.
    public private(set) var lastPushed: [Int: Frame]?
    /// The interface language: the user's last choice, else the system's.
    public private(set) var language: Language
    /// The language of the system-provided menus, app name and dialogs: the one the app
    /// launched with (macOS picks their localization once, at launch).
    public let menuLanguage: Language

    @ObservationIgnored private let service: any PushService
    @ObservationIgnored private let keepAwake: any KeepAwake
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let limiter = RenderLimiter(slots: 2)
    /// Pages of the running push that have not finished yet.
    @ObservationIgnored private var unfinished: Set<Int> = []

    static let maxLogLines = 200
    /// Where the language choice is kept: the app's own preferred languages, which macOS
    /// uses for `Locale.preferredLanguages` (in place of the system's) from the next launch
    /// and which System Settings' per-app language (Language & Region › Applications) sets
    /// too, so there is one choice, never two that disagree.
    static let languageKey = "AppleLanguages"

    /// `preferredLanguages` is the language list the app launched with: the app's own
    /// `AppleLanguages` (the toggle's last choice) when set, else the system's. The window
    /// starts in the language the system-provided menus use (`Language.systemDefault`).
    /// The toggle keeps its choice in `defaults`.
    public init(service: any PushService, keepAwake: any KeepAwake, defaults: UserDefaults = .standard,
                preferredLanguages: [String] = Locale.preferredLanguages) {
        self.service = service
        self.keepAwake = keepAwake
        self.defaults = defaults
        let language = Language.systemDefault(preferredLanguages: preferredLanguages)
        self.language = language
        menuLanguage = language
        pages = Panel.userSlots.map { PageModel(page: $0) }
    }

    /// The app's model, talking to the real device over Bluetooth. Every window shows this
    /// one, so the device does one job at a time however many windows are open, and a
    /// reopened window shows a push still running (Python: the single App / BleWorker).
    public static let shared = PushViewModel(service: LivePushService(), keepAwake: SystemKeepAwake())

    // MARK: state

    public var isBusy: Bool { job != nil }
    public var isPushing: Bool { job == .push }
    /// Photos, options and "讀取狀態" can be used (not during a job).
    public var canEdit: Bool { job == nil }
    public var canPush: Bool {
        job == nil && pages.contains { $0.frame != nil } && !pages.contains(where: \.isRendering)
    }
    /// After a successful push, once no preview is rendering (a tile's result must belong
    /// to the photo it shows).
    public var canVerify: Bool {
        job == nil && lastPushed != nil && !pages.contains(where: \.isRendering)
    }

    /// 「調整範圍…」: in Fill, once the page's photo is decoded, not during a job.
    public func canAdjustCrop(_ page: PageModel) -> Bool {
        canEdit && fit == .cover && page.photo != nil
    }

    public func page(_ page: Int) -> PageModel { pages[page - 1] }

    // MARK: language and texts

    /// Every text in the current language.
    public var strings: Strings { Strings(language) }
    public var summaryText: String { strings.summary(summary) }
    public var deviceStatusText: String { strings.deviceStatus(deviceStatus) }
    /// The "技術資訊" lines, oldest first.
    public var technicalLines: [String] { technicalLog.map(strings.logLine) }
    public var alertTitle: String? { alert.map(strings.alertTitle) }
    public var alertMessage: String? { alert.map(strings.alertMessage) }

    /// What `page`'s tile says under its progress bar.
    public func statusText(of page: PageModel) -> String { strings.pageStatus(page.status) }

    /// The window is in another language than the menus until the next launch: the window
    /// says so (`Strings.Key.menusNextLaunch`).
    public var menusSwitchAtNextLaunch: Bool { language != menuLanguage }

    /// Switch to the other language. Works at any time, also during a job; previews stay.
    public func toggleLanguage() {
        setLanguage(language.other)
    }

    /// Use `language` from now on, and from the next launch, when the system-provided menus
    /// follow (`menusSwitchAtNextLaunch`).
    public func setLanguage(_ language: Language) {
        self.language = language
        defaults.set([language.rawValue], forKey: Self.languageKey)
    }

    /// `[page: frame]` of every page with a rendered photo.
    public func frames() -> [Int: Frame] {
        pages.reduce(into: [:]) { frames, page in frames[page.page] = page.frame }
    }

    // MARK: photos and options

    /// Use `source` for `page` and render its preview.
    public func load(_ source: PhotoSource, into page: Int) {
        guard canEdit, Panel.userSlots.contains(page) else { return }
        let model = self.page(page)
        model.source = source
        model.photo = nil
        model.crop = nil
        model.name = source.name
        model.preview = nil
        model.failed = false
        render(model)
    }

    public func clear(page: Int) {
        guard canEdit, Panel.userSlots.contains(page) else { return }
        let model = self.page(page)
        cancelRender(model)
        model.source = nil
        model.photo = nil
        model.crop = nil
        model.name = nil
        model.preview = nil
        model.failed = false
        model.setProgress(.blank, 0)
    }

    public func setFit(_ fit: FitMode) {
        guard canEdit, fit != self.fit else { return }
        self.fit = fit
        rerender()
    }

    public func setGrain(_ grain: Grain) {
        guard canEdit, grain != self.grain else { return }
        self.grain = grain
        rerender()
    }

    private func rerender() {
        for page in pages where page.source != nil {
            render(page)
        }
    }

    // MARK: crop

    /// What the crop editor starts with for `page`: its photo's size and crop; nil when
    /// `canAdjustCrop` is false.
    public func cropGeometry(for page: Int) -> CropGeometry? {
        guard Panel.userSlots.contains(page) else { return nil }
        let model = self.page(page)
        guard canAdjustCrop(model), let size = model.photoSize else { return nil }
        return CropGeometry(photo: size, crop: model.crop)
    }

    /// Show `crop` of `page`'s photo in Fill (nil: the centred default) and render the page
    /// again (確定 in the crop editor). Only while `canAdjustCrop`, and only a crop that suits
    /// the photo (`Crop.validated` against its capped size, never the decoded copy's).
    public func setCrop(_ crop: Crop?, for page: Int) {
        guard Panel.userSlots.contains(page) else { return }
        let model = self.page(page)
        guard canAdjustCrop(model), let size = model.photoSize, crop != model.crop else { return }
        if let crop, (try? crop.validated(width: size.width, height: size.height)) == nil { return }
        model.crop = crop
        render(model)
    }

    /// Back to the centred crop (重設, then 確定).
    public func resetCrop(page: Int) {
        setCrop(nil, for: page)
    }

    /// (Re)compute the frame and preview of `page` off the main actor.
    private func render(_ page: PageModel) {
        guard let source = page.source else { return }
        cancelRender(page)
        let generation = page.generation
        page.isRendering = true
        page.setProgress(.rendering, 0)
        let job = RenderJob(source: source, photo: page.photo, fit: fit, crop: fit == .cover ? page.crop : nil,
                            grain: grain)
        let limiter = limiter
        page.renderTask = Task { [weak self, weak page] in
            let outcome = await job.run(limitedBy: limiter)
            guard let self, let page, page.generation == generation else { return }  // superseded
            self.finishRender(page, outcome)
        }
    }

    /// Supersede the running render of `page`, if any, and drop the old frame.
    private func cancelRender(_ page: PageModel) {
        page.generation += 1
        page.renderTask?.cancel()
        page.renderTask = nil
        page.frame = nil
        page.isRendering = false
    }

    private func finishRender(_ page: PageModel, _ outcome: Result<RenderJob.Output, any Error>) {
        page.isRendering = false
        switch outcome {
        case .success(let output):
            page.photo = output.photo
            page.frame = output.frame
            page.preview = output.preview
            if let name = output.photo.name { page.name = name }
            page.setProgress(.previewReady, 0)
        case .failure(let error):
            let name = page.name
            page.source = nil
            page.photo = nil
            page.crop = nil
            page.name = nil
            page.preview = nil
            page.failed = true
            page.setProgress(.previewFailed(name: name, reason: PreviewFailure(error)), 0)
        }
    }

    /// Wait until no page is rendering (tests).
    func waitForRenders() async {
        while let task = pages.first(where: \.isRendering)?.renderTask {
            await task.value
        }
    }

    // MARK: calendar jobs

    /// Upload every page with a frame; the page on screen goes last.
    public func push() async {
        guard canPush else { return }
        let frames = frames()
        for page in pages {
            page.setProgress(frames[page.page] == nil ? .blank : .waiting, 0)
        }
        unfinished = Set(frames.keys)
        lastPushed = nil
        summary = .pushing
        log(frames.sorted { $0.key < $1.key }.map { page, frame in
            .crc(page: page, crc32: frame.crc32, crc16: frame.crc16)
        })

        await run(.push) {
            // Events arrive from the session's actor; a stream keeps them in order and
            // all of them are shown before the result.
            let (events, sink) = AsyncStream.makeStream(of: PushEvent.self)
            let shown = Task { [weak self] in
                for await event in events { self?.show(event) }
            }
            let outcome: Result<[Int: UploadResult], any Error>
            do {
                outcome = .success(try await service.push(frames: frames) { sink.yield($0) })
            } catch {
                outcome = .failure(error)
            }
            sink.finish()
            await shown.value

            switch outcome {
            case .success(let results):
                let changed = results.values.filter { $0 == .ok }.count
                summary = .pushDone(changed: changed, unchanged: results.count - changed)
                deviceStatus = .justPushed
                lastPushed = frames
            case .failure(let error):
                summary = .pushFailed
                for page in unfinished.sorted() {
                    self.page(page).status = .unfinished  // keeps its progress bar
                }
                fail(.push, error)
            }
            unfinished = []
        }
    }

    /// Header-only probe of the frames of the last successful push: does each page still
    /// hold what was pushed? Nothing is written; matching pages do not refresh. A tile shows
    /// its result only while it still shows the pushed photo; the summary and the technical
    /// log cover every pushed page.
    public func verify() async {
        guard canVerify, let frames = lastPushed else { return }
        // Fixed during the job: photos and options are locked and nothing is rendering.
        let tiles = frames.keys.sorted().map { self.page($0) }.filter { $0.frame == frames[$0.page] }
        for tile in tiles {
            tile.status = .verifying
        }
        summary = .verifying

        await run(.verify) {
            do {
                let results = try await service.probe(frames: frames)
                for tile in tiles {
                    tile.status = results[tile.page].map(PageStatus.verified) ?? .notVerified
                }
                let sorted = results.sorted { $0.key < $1.key }
                log(sorted.map { .verified(page: $0.key, $0.value) })
                let differing = results.filter { $0.value == .differs }.map(\.key).sorted()
                let matching = results.filter { $0.value == .matches }.map(\.key).sorted()
                summary = .verifyDone(matching: matching, differing: differing)
            } catch {
                for tile in tiles {
                    tile.status = .notVerified
                }
                summary = .verifyFailed
                fail(.verify, error)
            }
        }
    }

    /// Battery and the page on screen.
    public func readInfo() async {
        guard canEdit else { return }
        deviceStatus = .connecting
        await run(.info) {
            do {
                deviceStatus = .status(try await service.info())
            } catch {
                deviceStatus = .unreachable
                fail(.info, error)
            }
        }
    }

    /// Run one calendar job with the app kept awake.
    private func run(_ job: Job, _ body: () async -> Void) async {
        self.job = job
        keepAwake.begin()
        defer {
            keepAwake.end()
            self.job = nil
        }
        await body()
    }

    private func show(_ event: PushEvent) {
        guard Panel.userSlots.contains(event.page) else { return }
        let progress = PushProgress(event)
        let model = page(event.page)
        if model.status != .progress(progress) || model.percent != progress.percent {
            model.setProgress(.progress(progress), progress.percent)
        }
        if [.done, .unchanged, .refreshing].contains(event.phase) {
            unfinished.remove(event.page)
        }
    }

    /// Log `job`'s error and show it.
    private func fail(_ job: Job, _ error: any Error) {
        log([.failed(job, detail: String(describing: error))])
        alert = Alert(job: job, error: error)
    }

    private func log(_ lines: [LogEntry]) {
        technicalLog.append(contentsOf: lines)
        if technicalLog.count > Self.maxLogLines {
            technicalLog.removeFirst(technicalLog.count - Self.maxLogLines)
        }
    }
}

/// Fetch and decode (once), then encode one page's photo, off the main actor.
struct RenderJob: Sendable {
    struct Output: Sendable {
        let photo: LoadedPhoto
        let frame: Frame
        let preview: CGImage
    }

    let source: PhotoSource
    /// The photo decoded by an earlier render, if any.
    let photo: LoadedPhoto?
    let fit: FitMode
    /// The page's crop in Fill (nil: the centred default); always nil in Fit.
    let crop: Crop?
    let grain: Grain

    /// Runs in a detached task; cancelling the caller cancels it. Fetching (maybe an iCloud
    /// download) holds no slot; decoding and encoding hold one of `limiter`'s (a cancelled
    /// job that still waits for a slot does no work).
    func run(limitedBy limiter: RenderLimiter) async -> Result<Output, any Error> {
        let work = Task.detached(priority: .userInitiated) { () async throws -> Output in
            try Task.checkCancellation()
            let input: Input
            if let photo {
                input = .decoded(photo)
            } else {
                input = .fetched(try await source.fetch())
            }
            await limiter.acquire()
            do {
                let output = try await render(input)
                await limiter.release()
                return output
            } catch {
                await limiter.release()
                throw error
            }
        }
        return await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
    }

    private enum Input: Sendable {
        case decoded(LoadedPhoto)
        case fetched(FetchedPhoto)
    }

    private func render(_ input: Input) async throws -> Output {
        try Task.checkCancellation()  // superseded while fetching or waiting for a slot
        let photo: LoadedPhoto
        switch input {
        case .decoded(let decoded):
            photo = decoded
        case .fetched(let fetched):
            let decoded = try await fetched.decode()
            photo = LoadedPhoto(image: decoded.image, size: decoded.size, name: fetched.name)
        }
        try Task.checkCancellation()
        let frame = FrameEncoder.encode(photo.image, fit: fit, crop: crop, dither: true, strength: grain.strength)
        try Task.checkCancellation()
        return Output(photo: photo, frame: frame, preview: frame.previewImage())
    }
}

/// At most `slots` decodes/encodes at a time: decoding a large photo takes memory and CPU
/// (Python: App.preview_slots).
actor RenderLimiter {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(slots: Int) {
        free = max(1, slots)
    }

    func acquire() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            free += 1
        } else {
            waiters.removeFirst().resume()  // the slot passes straight to the next waiter
        }
    }
}
