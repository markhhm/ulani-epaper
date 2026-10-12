import CoreGraphics
import Foundation
import Observation
import UlaniKit

/// State and actions of the app (Python: gui.App): four pages, the fit/dither options,
/// one calendar job at a time (push, status, verify).
///
/// Previews render off the main actor, at most two decoding at a time (fetching, e.g. an
/// iCloud download, holds no slot); a render superseded by a newer photo, a clear or an
/// option change is dropped (`PageModel.generation`).
@MainActor @Observable
public final class PushViewModel {
    public enum Job: Sendable, Equatable { case push, info, verify }

    public struct Alert: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let title: String
        public let message: String
    }

    public let pages: [PageModel]
    public private(set) var fit: FitMode = .cover
    public private(set) var dither = true
    /// The calendar job running now, if any.
    public private(set) var job: Job?
    public private(set) var summary = Strings.summaryIdle
    public private(set) var deviceStatus = Strings.deviceUnknown
    public var alert: Alert?
    /// Lines for the "技術資訊" section, oldest first.
    public private(set) var technicalLog: [String] = []
    /// The frames of the last successful push: what `verify` probes.
    public private(set) var lastPushed: [Int: Frame]?

    @ObservationIgnored private let service: any PushService
    @ObservationIgnored private let keepAwake: any KeepAwake
    @ObservationIgnored private let limiter = RenderLimiter(slots: 2)
    /// Pages of the running push that have not finished yet.
    @ObservationIgnored private var unfinished: Set<Int> = []

    static let maxLogLines = 200

    public init(service: any PushService, keepAwake: any KeepAwake) {
        self.service = service
        self.keepAwake = keepAwake
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

    public func page(_ page: Int) -> PageModel { pages[page - 1] }

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
        model.name = nil
        model.preview = nil
        model.failed = false
        model.setProgress("", 0)
    }

    public func setFit(_ fit: FitMode) {
        guard canEdit, fit != self.fit else { return }
        self.fit = fit
        rerender()
    }

    public func setDither(_ dither: Bool) {
        guard canEdit, dither != self.dither else { return }
        self.dither = dither
        rerender()
    }

    private func rerender() {
        for page in pages where page.source != nil {
            render(page)
        }
    }

    /// (Re)compute the frame and preview of `page` off the main actor.
    private func render(_ page: PageModel) {
        guard let source = page.source else { return }
        cancelRender(page)
        let generation = page.generation
        page.isRendering = true
        page.setProgress(Strings.rendering, 0)
        let job = RenderJob(source: source, photo: page.photo, fit: fit, dither: dither)
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
            page.setProgress(Strings.previewReady, 0)
        case .failure(let error):
            let name = page.name
            page.source = nil
            page.photo = nil
            page.name = nil
            page.preview = nil
            page.failed = true
            page.setProgress(Strings.previewError(name: name, error: error), 0)
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
            page.setProgress(frames[page.page] == nil ? "" : Strings.waiting, 0)
        }
        unfinished = Set(frames.keys)
        lastPushed = nil
        summary = Strings.summaryPushing
        log(frames.keys.sorted().map { Strings.crcLine(page: $0, frame: frames[$0]!) })

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
                summary = Strings.pushDone(changed: changed, unchanged: results.count - changed)
                deviceStatus = Strings.deviceJustPushed
                lastPushed = frames
            case .failure(let error):
                summary = Strings.summaryFailed
                for page in unfinished.sorted() {
                    self.page(page).status = Strings.unfinished  // keeps its progress bar
                }
                log(["\(Strings.pushFailedTitle)：\(error)"])
                alert = Alert(title: Strings.pushFailedTitle, message: Strings.friendly(error))
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
            tile.status = Strings.verifying
        }
        summary = Strings.summaryVerifying

        await run(.verify) {
            do {
                let results = try await service.probe(frames: frames)
                for tile in tiles {
                    tile.status = switch results[tile.page] {
                    case .matches: Strings.verifySame
                    case .differs: Strings.verifyDifferent
                    case nil: Strings.notVerified
                    }
                }
                let sorted = results.sorted { $0.key < $1.key }
                log(sorted.map { Strings.verifyLine(page: $0.key, result: $0.value) })
                let differing = results.filter { $0.value == .differs }.map(\.key).sorted()
                let matching = results.filter { $0.value == .matches }.map(\.key).sorted()
                summary = Strings.verifyDone(matching: matching, differing: differing)
            } catch {
                for tile in tiles {
                    tile.status = Strings.notVerified
                }
                summary = Strings.summaryVerifyFailed
                log(["\(Strings.verifyFailedTitle)：\(error)"])
                alert = Alert(title: Strings.verifyFailedTitle, message: Strings.friendly(error))
            }
        }
    }

    /// Battery and the page on screen.
    public func readInfo() async {
        guard canEdit else { return }
        deviceStatus = Strings.deviceConnecting
        await run(.info) {
            do {
                deviceStatus = Strings.deviceStatus(try await service.info())
            } catch {
                deviceStatus = Strings.deviceUnreachable
                log(["\(Strings.infoFailedTitle)：\(error)"])
                alert = Alert(title: Strings.infoFailedTitle, message: Strings.friendly(error))
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
        let (page, text, percent) = Strings.describe(event)
        guard Panel.userSlots.contains(page) else { return }
        let model = self.page(page)
        if model.status != text || model.percent != percent {
            model.setProgress(text, percent)
        }
        if [.done, .unchanged, .refreshing].contains(event.phase) {
            unfinished.remove(page)
        }
    }

    private func log(_ lines: [String]) {
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
    let dither: Bool

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
            photo = LoadedPhoto(image: try await fetched.decode(), name: fetched.name)
        }
        try Task.checkCancellation()
        let frame = FrameEncoder.encode(photo.image, fit: fit, dither: dither)
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
