import Foundation
import os

/// Protocol session on top of a connected `GattLink` (Python: `client.Calendar`).
///
/// Commands go to the command characteristic; their replies come back as notifications
/// and are matched by opcode. The link's notifications are forwarded into a `ReplyInbox`
/// by one task started in `start()`.
public actor CalendarSession {
    /// Outcome of a header-only probe.
    public enum ProbeResult: Sendable, Equatable {
        /// The page holds exactly this frame (`01 02`).
        case matches
        /// It does not (`01 00`, then the device gave up waiting for data).
        case differs
    }

    private let link: any GattLink
    private let timing: SessionTiming
    /// Read the firmware revision every N image chunks (nil: rely on the link's flow control).
    private let readBarrierEvery: Int?
    /// Replies waiting to be read; internal so tests can observe it.
    nonisolated let inbox = ReplyInbox()
    private var router: Task<Void, Never>?
    /// Page on screen, as last read with `0C`.
    private var shown: Int?
    /// We just replaced the page on screen: the panel refreshes (~40 s) and ignores commands.
    private var refreshing = false

    public init(link: any GattLink, timing: SessionTiming = .init(), readBarrierEvery: Int? = nil) {
        self.link = link
        self.timing = timing
        self.readBarrierEvery = readBarrierEvery.flatMap { $0 > 0 ? $0 : nil }
    }

    deinit {
        router?.cancel()
    }

    /// Start routing notifications (once) and unlock.
    public func start() async throws {
        startRouting()
        try await unlock()
    }

    public func unlock() async throws {
        let reply = try await command(Command.unlock)
        guard reply == Reply.unlockOK else { throw UlaniError.unlockRejected(reply) }
    }

    public func battery() async throws -> Battery {
        try Messages.parseBattery(try await command(Command.battery))
    }

    /// The page on screen and the CRC32 of its image.
    public func currentSlot() async throws -> (page: Int, crc32: UInt32) {
        let slot = try Messages.parseSlot(try await command(Command.getSlot))
        shown = slot.page
        return slot
    }

    public func deviceInfo() async throws -> DeviceInfo {
        try Messages.parseDeviceInfo(try await command(Command.deviceInfo))
    }

    /// Switch the page on screen to `page` (1-4).
    public func show(page: Int) async throws {
        let reply = try await command(try Messages.showSlot(page: page))
        guard reply == Reply.showSlotOK else {
            throw UlaniError.protocolError("show slot \(page) rejected: \(reply.hexString(separator: " "))")
        }
    }

    public func model() async throws -> String {
        String(decoding: try await link.read(.modelNumber), as: UTF8.self)
    }

    public func firmware() async throws -> String {
        String(decoding: try await link.read(.firmwareRevision), as: UTF8.self)
    }

    /// Send `frame` to `page` (Python: `Calendar.upload`).
    ///
    /// While the panel refreshes (~40 s after the page on screen changed) the device does
    /// not answer at all; unlock + header are resent until `busyTimeout` has passed.
    public func upload(_ frame: Frame, page: Int, mode: UInt8 = 1,
                       progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> UploadResult {
        let header = try Messages.imageHeader(frameBytes: frame.bytes, page: page, mode: Int(mode))
        let reply = try await whenReady("an image for page \(page)") {
            try await self.sendHeader(header)
        }
        if reply == Reply.headerSameImage { return .unchanged }
        guard reply == Reply.headerOK else { throw UlaniError.unexpectedHeaderReply(page: page, reply: reply) }

        await inbox.drain(.image)
        try await stream(frame.bytes, progress: progress)
        let result = try await inbox.next(on: .image, opcode: Opcode.imageData, timeout: timing.resultTimeout)
        guard result == Reply.dataOK else { throw UlaniError.uploadFailed(page: page, reply: result) }
        if page == shown {
            // The panel now refreshes for ~40 s and ignores every command.
            refreshing = true
        }
        return .ok
    }

    /// Upload several frames `[page: frame]` in this connection (Python: `push_pages`).
    ///
    /// Only replacing the page on screen makes the panel refresh (and go silent for
    /// ~40 s), so that page is uploaded last; the others go first in ascending order.
    /// `show` (1-4) switches the display to that page with a single refresh: when it is not
    /// the page on screen, every other page is uploaded first, then the display is
    /// switched, then the page that was on screen (no longer shown, so no second refresh;
    /// its upload waits out the refresh). The switch happens even if the page to show was
    /// unchanged or is not in `frames` (shared/BOARD.md).
    /// Stops at the first page that fails with a `PushError` naming that page and the
    /// pages already done; the remaining pages are not sent.
    public func push(_ frames: [Int: Frame], show: Int? = nil,
                     progress: (@Sendable (PushEvent) -> Void)? = nil) async throws -> [Int: UploadResult] {
        let bad = frames.keys.filter { !Panel.userSlots.contains($0) }.sorted()
        guard bad.isEmpty else { throw UlaniError.protocolError("pages must be 1-4, got \(bad)") }
        if let show, !Panel.userSlots.contains(show) {
            throw UlaniError.protocolError("the page to show must be 1-4, got \(show)")
        }
        let emit = progress ?? { _ in }

        let status = try await whenReady("a status query") { try await self.command(Command.getSlot) }
        let onScreen = try Messages.parseSlot(status).page
        shown = onScreen
        var switchTo = show == onScreen ? nil : show
        let order = PushPlan.order(pages: Array(frames.keys), shown: onScreen)
        var results: [Int: UploadResult] = [:]
        for (index, page) in order.enumerated() {
            guard let frame = frames[page] else { continue }
            let count = order.count, total = frame.bytes.count
            if let target = switchTo, page == onScreen {
                try await switchDisplay(to: target, index: index, count: count, emit: emit, completed: results)
                switchTo = nil
            }
            emit(PushEvent(page: page, phase: .start, index: index, count: count, sent: 0, total: total))
            let result: UploadResult
            do {
                result = try await upload(frame, page: page) { sent, total in
                    emit(PushEvent(page: page, phase: .sending, index: index, count: count, sent: sent, total: total))
                }
            } catch let error as UlaniError {
                throw PushError(page: page, completed: results, underlying: error)
            }
            results[page] = result
            emit(PushEvent(page: page, phase: result == .unchanged ? .unchanged : .done,
                           index: index, count: count, sent: total, total: total))
            if page == shown && result == .ok {
                emit(PushEvent(page: page, phase: .refreshing, index: index, count: count, sent: total, total: total))
            }
        }
        if let target = switchTo {
            try await switchDisplay(to: target, index: order.count, count: order.count, emit: emit, completed: results)
        }
        return results
    }

    /// `push`'s display switch: show `page`; the panel then refreshes for ~40 s and ignores
    /// every command. A failure is a `PushError` naming `page`.
    private func switchDisplay(to page: Int, index: Int, count: Int, emit: (PushEvent) -> Void,
                               completed: [Int: UploadResult]) async throws {
        emit(PushEvent(page: page, phase: .switching, index: index, count: count))
        do {
            let message = try Messages.showSlot(page: page)
            let reply = try await whenReady("switching to page \(page)") { try await self.command(message) }
            guard reply == Reply.showSlotOK else {
                throw UlaniError.protocolError("switching the display was rejected: \(reply.hexString(separator: " "))")
            }
        } catch let error as UlaniError {
            throw PushError(page: page, completed: completed, underlying: error)
        }
        shown = page
        refreshing = true
    }

    /// Header-only probe: does `page` hold exactly `frame`? Nothing is written and the
    /// panel does not refresh when it does (`01 02`). Otherwise the device answers `01 00`,
    /// waits for data and gives up with `02 01` after ~4 s (hardware: whether the stored
    /// page survives that is untested), so only probe pages you expect to match. The probe
    /// waits for that `02 xx` (see `probeGiveUpWait`) and answers `.differs` either way.
    public func probe(page: Int, frame: Frame, mode: UInt8 = 1) async throws -> ProbeResult {
        guard Panel.userSlots.contains(page) else {
            throw UlaniError.protocolError("pages must be 1-4, got [\(page)]")
        }
        let header = try Messages.imageHeader(frameBytes: frame.bytes, page: page, mode: Int(mode))
        await inbox.drain(.image)
        let reply = try await whenReady("a probe of page \(page)") { try await self.sendHeader(header) }
        if reply == Reply.headerSameImage { return .matches }
        guard reply == Reply.headerOK else { throw UlaniError.unexpectedHeaderReply(page: page, reply: reply) }
        // `01 00` is the answer. Give the device time to give up, so the next command finds
        // it idle; a missing `02 xx` does not change the answer.
        do {
            _ = try await inbox.next(on: .image, opcode: Opcode.imageData, timeout: Self.probeGiveUpWait(timing))
        } catch UlaniError.noReply {}
        return .differs
    }

    /// Tell the calendar we are done so it can go back to sleep (best effort).
    ///
    /// Skipped right after the page on screen was replaced: the device is refreshing and
    /// would ignore it, costing a full reply timeout.
    public func sayGoodbye() async {
        guard !refreshing else { return }
        _ = try? await command(Command.disconnect)
    }

    /// How long a probe answered `01 00` waits for the device to give up (~4 s on hardware):
    /// a reply timeout plus 5 s, at most `resultTimeout`.
    static func probeGiveUpWait(_ timing: SessionTiming) -> Duration {
        min(timing.resultTimeout, timing.replyTimeout + .seconds(5))
    }

    /// Chunk size for a link's write length: at most 230 (`Panel.maxChunk`), at least 20.
    static func chunkSize(forWriteLength length: Int) -> Int {
        min(Panel.maxChunk, max(20, length))
    }

    /// One attempt to announce an image: unlock, then the header. nil means "busy" (`01 01`).
    private func sendHeader(_ header: Data) async throws -> Data? {
        try await unlock()
        let reply = try await command(header)
        return reply == Reply.headerBusy ? nil : reply
    }

    /// Run `attempt` until it answers; retry while the device is silent (`noReply`) or
    /// busy (nil), every `retryDelay`, until `busyTimeout` -> `deviceBusy`.
    private func whenReady(_ what: String, _ attempt: () async throws -> Data?) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now + timing.busyTimeout
        while true {
            var reply: Data?
            do {
                reply = try await attempt()
            } catch UlaniError.noReply {
                reply = nil
            }
            if let reply { return reply }
            if clock.now >= deadline { throw UlaniError.deviceBusy(what: what) }
            try await Task.sleep(for: timing.retryDelay)
        }
    }

    /// Stream `bytes` to the image characteristic; stop early as soon as an image reply
    /// arrived (the device gave up) or the task is cancelled (Python: the upload is
    /// cancelled at the `sleep(0)` before each chunk). With a read barrier, stream in groups
    /// of that many chunks and read the firmware revision between groups (not after the
    /// last chunk).
    private func stream(_ bytes: Data, progress: (@Sendable (Int, Int) -> Void)?) async throws {
        let size = Self.chunkSize(forWriteLength: await link.maximumWriteLength())
        let total = bytes.count
        let inbox = self.inbox
        // A link may call `shouldStop` outside this task, where `Task.isCancelled` is false,
        // so cancellation is recorded in a flag.
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let shouldStop: @Sendable () -> Bool = { cancelled.withLock { $0 } || inbox.hasPending(.image) }
        let group = readBarrierEvery.map { $0 > total / size ? total : $0 * size } ?? total
        try await withTaskCancellationHandler {
            var sent = 0
            while sent < total {
                let offset = sent, end = min(total, offset + group)
                let part = Data(bytes[bytes.startIndex + offset ..< bytes.startIndex + end])
                sent += try await link.streamImage(part, chunkSize: size, progress: { done, _ in
                    progress?(offset + done, total)
                }, shouldStop: shouldStop)
                try Task.checkCancellation()
                if sent < end { break }  // stopped early: the device already answered
                if readBarrierEvery != nil && sent < total {
                    _ = try await link.read(.firmwareRevision)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Write a command and return the notification that answers it (same opcode).
    /// Stale replies are dropped first.
    func command(_ payload: Data) async throws -> Data {
        guard let opcode = payload.first else { throw UlaniError.protocolError("empty command") }
        startRouting()
        await inbox.drain(.command)
        try await link.writeCommand(payload)
        return try await inbox.next(on: .command, opcode: opcode, timeout: timing.replyTimeout)
    }

    private func startRouting() {
        guard router == nil else { return }
        let notifications = link.notifications
        let inbox = self.inbox
        router = Task { await Self.forward(notifications, to: inbox) }
    }

    private static func forward(_ notifications: AsyncStream<GattNotification>, to inbox: ReplyInbox) async {
        for await notification in notifications {
            await inbox.deliver(notification)
        }
        await inbox.close(reason: "the device disconnected")
    }
}
