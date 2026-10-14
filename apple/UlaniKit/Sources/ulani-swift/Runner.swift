import Foundation
import os
import UlaniKit

/// How the CLI reaches the calendar. Tests substitute the link and shorten the waits.
struct Connection: Sendable {
    typealias MakeLink = @Sendable (Invocation) async throws -> any GattLink

    /// Setup attempts and the pause between them (CalendarConnector's defaults).
    var attempts = 4
    var retryDelay: Duration = .seconds(5)
    var timing = SessionTiming()
    var makeLink: MakeLink

    /// The real transports: the relay given with `--relay`, otherwise CoreBluetooth.
    static let live = Connection { invocation in
        switch invocation.transport {
        case .relay(let host, let port):
            try await RelayLink.connect(host: host, port: port, scanTimeout: invocation.scanTimeout,
                                        flushEvery: invocation.relayFlushEvery)
        case .bluetooth:
            try await CoreBluetoothLink.connect(scanTimeout: invocation.scanTimeout)
        }
    }
}

enum CLI {
    /// Run the command line `arguments` (without the program name); returns the exit status.
    static func main(_ arguments: [String], console: Console, connection: Connection) async -> Int32 {
        let parsed: Parsed
        do {
            parsed = try Arguments.parse(arguments)
        } catch {
            console.errorLine("ulani-swift: \(error)")
            console.errorLine("run 'ulani-swift --help' for usage")
            return 2
        }
        switch parsed {
        case .help:
            console.writeOut(Arguments.usage)
            return 0
        case .version:
            console.line("ulani-swift \(UlaniKit.version)")
            return 0
        case .run(let invocation):
            return await Runner(invocation: invocation, console: console, connection: connection).run()
        }
    }
}

/// Runs one invocation: info, show, push or probe.
struct Runner: Sendable {
    /// A page to upload or probe, encoded.
    private struct Page: Sendable {
        let page: Int
        let path: String
        let crop: Crop?
        let frame: Frame
    }

    /// A session's result and how long the setup and the work took.
    private struct Timed<Value: Sendable>: Sendable {
        let value: Value
        let connect: Duration
        let work: Duration
    }

    private struct CalendarStatus: Sendable {
        let info: DeviceInfo
        let battery: Battery
        let slot: (page: Int, crc32: UInt32)
        let model: String
        let firmware: String
    }

    let invocation: Invocation
    let console: Console
    let connection: Connection
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant

    init(invocation: Invocation, console: Console, connection: Connection) {
        self.invocation = invocation
        self.console = console
        self.connection = connection
        started = clock.now
    }

    func run() async -> Int32 {
        do {
            switch invocation.command {
            case .info:
                try await info()
                return 0
            case .show:
                try await show()
                return 0
            case .push:
                try await push()
                return 0
            case .probe:
                return try await probe() ? 0 : 1
            }
        } catch is CancellationError {
            console.errorLine("interrupted")
            return 130
        } catch let error as UsageError {  // a --crop that does not suit its photo
            console.errorLine("ulani-swift: \(error)")
            console.errorLine("run 'ulani-swift --help' for usage")
            return 2
        } catch {
            console.errorLine("error: \(error)")
            return 1
        }
    }

    // MARK: commands

    private func info() async throws {
        let status = try await withCalendar { session in
            CalendarStatus(info: try await session.deviceInfo(), battery: try await session.battery(),
                           slot: try await session.currentSlot(), model: try await session.model(),
                           firmware: try await session.firmware())
        }.value
        console.line("model      \(status.model)")
        console.line("firmware   \(status.firmware)")
        console.line("serial     \(status.info.serial)")
        console.line("mac        \(status.info.mac)")
        console.line("battery    \(status.battery.level.map { "\($0)/5" } ?? "charging")")
        console.line("showing    page \(status.slot.page) (image crc32 \(Format.crc32(status.slot.crc32)))")
    }

    /// Put a page on screen, as the device's button does.
    ///
    /// The session's `show` sends `0B` whatever is on screen, so the page on screen is read
    /// first: one `0C` round trip, as info does. That says which page was there and, when it
    /// is the page asked for, saves the `0B` (whether the device would redraw the panel for
    /// it, ~40 s, is untested). Nothing is read back after a switch: the panel is redrawing.
    private func show() async throws {
        let page = invocation.pages[0]  // the parser allows exactly one
        let start = clock.now
        let timed = try await withCalendar { session in
            let shown = try await session.currentSlot().page
            guard shown != page else {
                event("page \(page) is already on screen; nothing to do")
                return
            }
            event("page \(shown) on screen; switching to page \(page)")
            try await session.show(page: page)
            event("  page \(page) is on screen: the panel refreshes now (~40 s)")
        }
        console.line("done in \(Format.seconds(clock.now - start)) (connect \(Format.seconds(timed.connect)), "
                     + "show \(Format.seconds(timed.work)))")
    }

    private func push() async throws {
        let pages = try encode()
        guard !invocation.dryRun else { return }
        let frames = Dictionary(uniqueKeysWithValues: pages.map { ($0.page, $0.frame) })
        let reporter = PushReporter(console: console, bar: console.interactive && !invocation.verbose) {
            Format.stamp(clock.now - started)
        }
        let start = clock.now
        let timed: Timed<[Int: UploadResult]>
        do {
            timed = try await withCalendar { session in
                try await session.push(frames) { reporter.handle($0) }
            }
        } catch let error as PushError {
            reporter.finish()
            let order = reporter.order.map(String.init).joined(separator: ", ")
            console.line("order    \(order) (stopped at page \(error.page))")
            let done = Self.describe(error.completed)
            console.line("results  \(done.isEmpty ? "" : done + "; ")page \(error.page) failed")
            let notSent = Set(frames.keys).subtracting(error.completed.keys).subtracting([error.page])
            if !notSent.isEmpty {
                console.line("not sent page \(Format.pages(notSent))")
            }
            throw error
        } catch {
            reporter.finish()
            throw error
        }
        reporter.finish()
        let results = timed.value
        var order = "order    " + reporter.order.map(String.init).joined(separator: ", ")
        if let shown = reporter.refreshed {
            order += " (page \(shown) was on screen, so it went last)"
        }
        console.line(order)
        console.line("results  \(Self.describe(results))")
        let uploaded = results.values.filter { $0 == .ok }.count
        console.line("done in \(Format.seconds(clock.now - start)) (connect \(Format.seconds(timed.connect)), "
                     + "push \(Format.seconds(timed.work))): \(uploaded) page(s) uploaded, "
                     + "\(results.count - uploaded) unchanged")
    }

    /// Header-only probe of every page; true when all match.
    private func probe() async throws -> Bool {
        let pages = try encode()
        guard !invocation.dryRun else { return true }
        let start = clock.now
        let timed = try await withCalendar { session in
            var differing: [Int] = []
            for page in pages {
                let result = try await session.probe(page: page.page, frame: page.frame)
                event("page \(page.page) \(result == .matches ? "matches" : "differs")")
                if result == .differs { differing.append(page.page) }
            }
            return differing
        }
        let differing = timed.value
        if differing.isEmpty {
            console.line("all \(pages.count) page(s) match")
        } else {
            console.line("\(pages.count - differing.count) of \(pages.count) page(s) match; "
                         + "page(s) \(Format.pages(differing)) differ")
        }
        console.line("done in \(Format.seconds(clock.now - start)) (connect \(Format.seconds(timed.connect)), "
                     + "probe \(Format.seconds(timed.work)))")
        return differing.isEmpty
    }

    // MARK: steps

    /// Encode the images as Paperhue does and print each page's CRCs. A `--crop` that does
    /// not suit its photo is a usage error.
    private func encode() throws -> [Page] {
        let start = clock.now
        var pages: [Page] = []
        for (page, path) in invocation.assignments {
            let url = URL(fileURLWithPath: path)
            let photo = try FrameEncoder.loadPhoto(url: url)
            let crop = try invocation.crops[page].map { crop throws(UsageError) in
                do {
                    return try crop.validated(width: photo.size.width, height: photo.size.height)
                } catch {
                    throw UsageError(description: "--crop for page \(page) does not fit \(url.lastPathComponent) "
                                     + "(\(photo.size) px): \(error)")
                }
            }
            let frame = FrameEncoder.encode(photo.image, fit: invocation.fit, crop: crop, dither: invocation.dither,
                                            strength: invocation.strength, colours: invocation.colours)
            pages.append(Page(page: page, path: path, crop: crop, frame: frame))
        }
        pages.sort { $0.page < $1.page }
        let mapping = !invocation.dither ? "nearest colour"
            : "\(invocation.colours.rawValue), "
                + (invocation.strength == 1 ? "dithered" : "dithered, strength \(invocation.strength)")
        console.line("encoded \(pages.count) image(s) (\(invocation.fit.rawValue), \(mapping)) "
                     + "in \(Format.seconds(clock.now - start))")
        for page in pages {
            let crop = page.crop.map { "crop \($0.left),\($0.top),\($0.width),\($0.height)  " } ?? ""
            console.line("page \(page.page)  CRC32 \(Format.crc32(page.frame.crc32))  "
                         + "CRC16 \(Format.crc16(page.frame.crc16))  \(crop)\(page.path)")
        }
        return pages
    }

    /// Set up (retried as one unit), run `work`, say goodbye and disconnect.
    private func withCalendar<Value: Sendable>(
        _ work: @escaping @Sendable (CalendarSession) async throws -> Value
    ) async throws -> Timed<Value> {
        let name = transportName
        console.line("connecting via \(name)")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let connected = OSAllocatedUnfairLock<String?>(initialState: nil)
        // The relay host has its own read barrier (--flush-every goes there).
        let readBarrier = invocation.transport == .bluetooth ? invocation.readBarrierEvery : nil
        let connector = CalendarConnector(attempts: connection.attempts, retryDelay: connection.retryDelay,
                                          timing: connection.timing, readBarrierEvery: readBarrier) {
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            if attempt > 1 {
                event("connecting again (attempt \(attempt) of \(connection.attempts))")
            }
            let link: any GattLink
            do {
                link = try await connection.makeLink(invocation)
            } catch {
                // A cancel (Ctrl-C) is reported once, as `interrupted`.
                if !(error is CancellationError) { event("  setup failed: \(error)") }
                throw error
            }
            let length = await link.maximumWriteLength()
            let fake = (link as? RelayLink)?.isFake == true ? " (fake device)" : ""
            connected.withLock { $0 = "\(name)\(fake), write length \(length)" }
            guard invocation.verbose else { return link }
            return TracingLink(link) { trace($0) }
        }
        let start = clock.now
        return try await connector.withCalendar { session in
            let ready = clock.now
            event("connected: \(connected.withLock { $0 } ?? name)")
            let value = try await work(session)
            return Timed(value: value, connect: ready - start, work: clock.now - ready)
        }
    }

    private var transportName: String {
        switch invocation.transport {
        case .bluetooth: "Bluetooth"
        case .relay(let host, let port): "relay \(host.contains(":") ? "[\(host)]" : host):\(port)"
        }
    }

    /// A line on stdout, stamped with the time since the command started.
    private func event(_ text: String) {
        console.line("\(Format.stamp(clock.now - started)) \(text)")
    }

    /// A `--verbose` trace line on stderr, stamped like the events.
    private func trace(_ text: String) {
        console.errorLine("\(Format.stamp(clock.now - started)) \(text)")
    }

    /// `page 1 ok, page 2 unchanged`.
    private static func describe(_ results: [Int: UploadResult]) -> String {
        results.sorted { $0.key < $1.key }.map { "page \($0.key) \($0.value.rawValue)" }.joined(separator: ", ")
    }
}

/// Prints push events as they arrive (from the session's task) and remembers the order.
final class PushReporter: Sendable {
    private struct State: Sendable {
        var order: [Int] = []
        var refreshed: Int?
        /// Last quarter of progress printed, per page (lines mode).
        var quarters: [Int: Int] = [:]
        var barOpen = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let console: Console
    /// Draw a progress bar on stderr; otherwise print a line at every quarter.
    private let bar: Bool
    private let stamp: @Sendable () -> String

    init(console: Console, bar: Bool, stamp: @escaping @Sendable () -> String) {
        self.console = console
        self.bar = bar
        self.stamp = stamp
    }

    /// Pages in the order they were started.
    var order: [Int] { state.withLock { $0.order } }
    /// The page on screen, once its replacement made the panel refresh.
    var refreshed: Int? { state.withLock { $0.refreshed } }

    func handle(_ event: PushEvent) {
        // Printed under the lock, so lines keep the order of the events.
        state.withLock { s in
            let page = event.page
            switch event.phase {
            case .start:
                s.order.append(page)
                line("page \(page) (\(event.index + 1)/\(event.count))")
            case .sending where bar:
                let complete = event.sent >= event.total
                console.writeErr(Format.bar(sent: event.sent, total: event.total) + (complete ? "\n" : ""))
                s.barOpen = !complete
            case .sending:
                let quarter = event.total > 0 ? event.sent * 4 / event.total : 4
                if quarter > s.quarters[page, default: 0] {
                    s.quarters[page] = quarter
                    line("  sent \(event.sent) of \(event.total) bytes (\(quarter * 25)%)")
                }
            case .done:
                line("  page \(page) done")
            case .unchanged:
                line("  page \(page) already holds this image; skipped")
            case .refreshing:
                s.refreshed = page
                line("  page \(page) is on screen: the panel refreshes now (~40 s)")
            case .switching:
                line("  switching the display to page \(page): the panel refreshes now (~40 s)")
            }
        }
    }

    /// End a progress bar a stopped upload left open.
    func finish() {
        state.withLock { s in
            if s.barOpen { console.writeErr("\n") }
            s.barOpen = false
        }
    }

    private func line(_ text: String) {
        console.line("\(stamp()) \(text)")
    }
}
