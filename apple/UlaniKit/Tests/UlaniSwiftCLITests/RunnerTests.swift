import CoreGraphics
import Foundation
import ImageIO
import os
import Testing
import UlaniKit
@testable import ulani_swift

/// Everything the CLI wrote.
final class Captured: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (out: "", err: ""))

    func console(interactive: Bool = false) -> Console {
        Console(writeOut: { text in self.lock.withLock { $0.out += text } },
                writeErr: { text in self.lock.withLock { $0.err += text } },
                interactive: interactive)
    }

    var out: String { lock.withLock { $0.out } }
    var err: String { lock.withLock { $0.err } }
    var outLines: [String] { out.split(separator: "\n").map(String.init) }
    var errLines: [String] { err.split(separator: "\n").map(String.init) }
}

/// Four small PNGs in solid colours in a fresh folder.
struct Pictures {
    let folder: URL
    let paths: [String]

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ulani-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        let colours: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 0, 1), (0, 1, 0), (1, 1, 0)]
        paths = try colours.enumerated().map { index, colour in
            let url = folder.appending(path: "photo\(index + 1).png")
            try Self.writePNG(url, colour: colour)
            return url.path(percentEncoded: false)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A 1200x900 PNG in the folder: red, green, blue and yellow quarters (top left, top
    /// right, bottom left, bottom right).
    func quadrants() throws -> String {
        let context = CGContext(data: nil, width: 1200, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (x, y, r, g, b) in [(0, 450, 1, 0, 0), (600, 450, 0, 1, 0), (0, 0, 0, 0, 1), (600, 0, 1, 1, 0)] as [(Int, Int, CGFloat, CGFloat, CGFloat)] {
            context.setFillColor(red: r, green: g, blue: b, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 600, height: 450))  // origin bottom left
        }
        let url = folder.appending(path: "quadrants.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url.path(percentEncoded: false)
    }

    /// The frame push encodes for `path`.
    static func frame(_ path: String, fit: FitMode = .cover, dither: Bool = true) throws -> Frame {
        FrameEncoder.encode(try FrameEncoder.loadImage(url: URL(fileURLWithPath: path)), fit: fit, dither: dither)
    }

    /// The line push and probe print for a page.
    static func crcLine(page: Int, path: String, fit: FitMode = .cover, dither: Bool = true) throws -> String {
        let frame = try frame(path, fit: fit, dither: dither)
        return "page \(page)  CRC32 \(String(format: "%08x", frame.crc32))  CRC16 \(String(format: "%04x", frame.crc16))  \(path)"
    }

    private static func writePNG(_ url: URL, colour: (CGFloat, CGFloat, CGFloat)) throws {
        let context = CGContext(data: nil, width: 80, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 48))
        // A white corner, so cover and contain differ.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

@Suite struct RunnerTests {
    static let timing = SessionTiming(replyTimeout: .seconds(2), resultTimeout: .seconds(5),
                                      busyTimeout: .seconds(5), retryDelay: .milliseconds(10))

    private func connection(_ calendar: StubCalendar) -> Connection {
        Connection(attempts: 2, retryDelay: .milliseconds(10), timing: Self.timing) { _ in calendar.link() }
    }

    /// For runs that must not reach a calendar (the real transport is never used in tests).
    private let noConnection = Connection(attempts: 1, retryDelay: .zero, timing: timing) { _ in
        Issue.record("the CLI connected")
        throw UlaniError.notFound
    }

    private func run(_ arguments: [String], _ connection: Connection,
                     interactive: Bool = false) async -> (status: Int32, output: Captured) {
        let captured = Captured()
        let status = await CLI.main(arguments, console: captured.console(interactive: interactive),
                                    connection: connection)
        return (status, captured)
    }

    /// One attempt and no timeout that could end the run first: only a cancel does.
    private func patientConnection(_ calendar: StubCalendar) -> Connection {
        let timing = SessionTiming(replyTimeout: .seconds(60), resultTimeout: .seconds(60),
                                   busyTimeout: .seconds(60), retryDelay: .milliseconds(10))
        return Connection(attempts: 1, retryDelay: .zero, timing: timing) { _ in calendar.link() }
    }

    /// Run `arguments` in a task and cancel it (what Ctrl-C does) once `ready` holds.
    private func cancelledRun(_ arguments: [String], _ connection: Connection,
                              once ready: @escaping @Sendable () -> Bool) async throws -> (status: Int32, output: Captured) {
        let captured = Captured()
        let task = Task { await CLI.main(arguments, console: captured.console(), connection: connection) }
        do {
            try await waitUntil(ready)
        } catch {
            task.cancel()
            throw error
        }
        task.cancel()
        return (await task.value, captured)
    }

    @Test func info() async throws {
        let calendar = StubCalendar()
        let (status, output) = await run(["info", "--relay", "127.0.0.1:9"], connection(calendar))
        #expect(status == 0, "\(output.err)")
        for line in ["model      P7320E-B", "firmware   v1.0.09", "serial     STUB0001", "mac        02:00:00:00:00:01",
                     "battery    4/5", "showing    page 1 (image crc32 00000000)"] {
            #expect(output.outLines.contains(line), "missing \(line) in\n\(output.out)")
        }
        #expect(calendar.state.commands.last == Data([0x09, 0x03]))  // goodbye
    }

    @Test func showSwitchesThePageAndSaysThePanelRefreshes() async throws {
        let calendar = StubCalendar()  // page 1 on screen
        let (status, output) = await run(["show", "--relay", "127.0.0.1:9", "3"], connection(calendar))
        #expect(status == 0, "\(output.err)")
        let lines = output.outLines
        #expect(lines.first == "connecting via relay 127.0.0.1:9")
        let events = lines.filter { $0.hasPrefix("[") }.map { String($0.drop { $0 != "]" }.dropFirst(2)) }
        #expect(events == [
            "connected: relay 127.0.0.1:9, write length 244",
            "page 1 on screen; switching to page 3",
            "  page 3 is on screen: the panel refreshes now (~40 s)",
        ])
        #expect(lines.last.map { $0.hasPrefix("done in ") && $0.contains(" s (connect ") && $0.hasSuffix(" s)")
                                 && $0.contains(" s, show ") } == true, "\(output.out)")
        // Unlock, the page on screen, show page 3, goodbye.
        #expect(calendar.state.commands == [Data([0x04, 0x4E, 0x42]), Data([0x0C, 0x00]), Data([0x0B, 0x03]),
                                            Data([0x09, 0x03])])
        #expect(calendar.state.shown == 3)
    }

    @Test func showSendsNothingWhenThePageIsAlreadyOnScreen() async throws {
        let calendar = StubCalendar { $0.shown = 2 }
        let (status, output) = await run(["show", "2"], connection(calendar))
        #expect(status == 0, "\(output.err)")
        #expect(output.outLines.contains { $0.hasSuffix("] page 2 is already on screen; nothing to do") })
        #expect(!output.out.contains("switching") && !output.out.contains("refreshes"), "\(output.out)")
        #expect(output.outLines.last?.hasPrefix("done in ") == true)
        #expect(calendar.state.commands == [Data([0x04, 0x4E, 0x42]), Data([0x0C, 0x00]), Data([0x09, 0x03])])
    }

    @Test func rejectedShowExits1WithoutGoodbye() async throws {
        let calendar = StubCalendar { $0.rejectShow = true }
        let (status, output) = await run(["show", "4"], connection(calendar))
        #expect(status == 1)
        #expect(output.outLines.contains { $0.hasSuffix("] page 1 on screen; switching to page 4") })
        #expect(!output.out.contains("refreshes") && !output.out.contains("done in"), "\(output.out)")
        #expect(output.errLines == ["error: show slot 4 rejected: 0b 01"])
        #expect(calendar.state.shown == 1)
        #expect(calendar.state.disconnects == 1)
        #expect(!calendar.state.commands.contains(Data([0x09, 0x03])))
    }

    @Test func pushPrintsCRCsEventsOrderAndTimeThenAgainUnchanged() async throws {
        let pictures = try Pictures()
        defer { pictures.remove() }
        let calendar = StubCalendar()  // page 1 on screen: it goes last
        let paths = Array(pictures.paths.prefix(2))
        let (status, output) = await run(["push", "--relay", "127.0.0.1:9"] + paths, connection(calendar))
        #expect(status == 0, "\(output.err)")
        let lines = output.outLines
        #expect(lines.contains(try Pictures.crcLine(page: 1, path: paths[0])))
        #expect(lines.contains(try Pictures.crcLine(page: 2, path: paths[1])))
        #expect(lines.contains { $0.hasPrefix("encoded 2 image(s) (cover, dithered) in ") })
        #expect(lines.contains { $0.hasSuffix("] connected: relay 127.0.0.1:9, write length 244") })
        let events = lines.filter { $0.hasPrefix("[") }.map { String($0.drop { $0 != "]" }.dropFirst(2)) }
        #expect(events.filter { !$0.contains("bytes (") } == [
            "connected: relay 127.0.0.1:9, write length 244",
            "page 2 (1/2)", "  page 2 done",
            "page 1 (2/2)", "  page 1 done", "  page 1 is on screen: the panel refreshes now (~40 s)",
        ])
        // Progress in quarters (not a terminal).
        #expect(events.filter { $0.hasPrefix("  sent ") }.map { $0.split(separator: "(").last! }
                == ["25%)", "50%)", "75%)", "100%)", "25%)", "50%)", "75%)", "100%)"])
        #expect(events.contains("  sent 192000 of 192000 bytes (100%)"))
        #expect(lines.contains("order    2, 1 (page 1 was on screen, so it went last)"))
        #expect(lines.contains("results  page 1 ok, page 2 ok"))
        #expect(lines.contains { $0.hasPrefix("done in ") && $0.contains(" s (connect ") &&
                                 $0.hasSuffix(" s): 2 page(s) uploaded, 0 unchanged") })
        #expect(calendar.state.imageBytes == 2 * Frame.byteCount)

        let (again, second) = await run(["push", "--relay", "127.0.0.1:9"] + paths, connection(calendar))
        #expect(again == 0, "\(second.err)")
        #expect(second.outLines.contains { $0.hasSuffix("] page 2 (1/2)") })
        #expect(second.outLines.contains { $0.hasSuffix("]   page 2 already holds this image; skipped") })
        #expect(second.outLines.contains("order    2, 1"))
        #expect(second.outLines.contains("results  page 1 unchanged, page 2 unchanged"))
        #expect(second.outLines.contains { $0.hasSuffix(": 0 page(s) uploaded, 2 unchanged") })
        #expect(calendar.state.imageBytes == 2 * Frame.byteCount)
    }

    @Test func probeMatchesAfterPushAndExits1WhenAPageDiffers() async throws {
        let pictures = try Pictures()
        defer { pictures.remove() }
        let calendar = StubCalendar()
        let paths = pictures.paths
        #expect(await run(["push"] + paths, connection(calendar)).status == 0)
        let sent = calendar.state.imageBytes

        let (status, output) = await run(["probe"] + paths, connection(calendar))
        #expect(status == 0, "\(output.err)")
        for page in 1...4 {
            #expect(output.outLines.contains(try Pictures.crcLine(page: page, path: paths[page - 1])))
            #expect(output.outLines.contains { $0.hasSuffix("] page \(page) matches") })
        }
        #expect(output.outLines.contains("all 4 page(s) match"))
        #expect(calendar.state.imageBytes == sent)  // header-only

        let (differs, swapped) = await run(["probe", "--pages", "2,1", paths[0], paths[1]], connection(calendar))
        #expect(differs == 1)
        #expect(swapped.outLines.contains { $0.hasSuffix("] page 1 differs") })
        #expect(swapped.outLines.contains { $0.hasSuffix("] page 2 differs") })
        #expect(swapped.outLines.contains("0 of 2 page(s) match; page(s) 1, 2 differ"))
        #expect(calendar.state.imageBytes == sent)
    }

    @Test func failedPushNamesThePageAndWhatWasDone() async throws {
        let pictures = try Pictures()
        defer { pictures.remove() }
        let calendar = StubCalendar { $0.failPages = [3] }
        let paths = Array(pictures.paths.prefix(3))
        let (status, output) = await run(["push"] + paths, connection(calendar))
        #expect(status == 1)
        #expect(output.outLines.contains("order    2, 3 (stopped at page 3)"))
        #expect(output.outLines.contains("results  page 2 ok; page 3 failed"))
        #expect(output.outLines.contains("not sent page 1"))
        #expect(output.errLines.contains("error: page 3: device reported failure: 02 01"))
    }

    @Test func dryRunEncodesWithoutConnecting() async throws {
        let pictures = try Pictures()
        defer { pictures.remove() }
        let paths = Array(pictures.paths.prefix(2))
        let (status, output) = await run(["push", "--dry-run", "--fit", "contain", "--no-dither", "--pages", "4,2"] + paths,
                                         noConnection)
        #expect(status == 0, "\(output.err)")
        #expect(output.outLines.contains { $0.hasPrefix("encoded 2 image(s) (contain, nearest colour) in ") })
        let crcLines = output.outLines.filter { $0.hasPrefix("page ") }
        #expect(crcLines == [try Pictures.crcLine(page: 2, path: paths[1], fit: .contain, dither: false),
                             try Pictures.crcLine(page: 4, path: paths[0], fit: .contain, dither: false)])
        #expect(await run(["probe", "--dry-run", paths[0]], noConnection).status == 0)
    }

    @Test func cropChoosesThePartOfThePhoto() async throws {
        let pictures = try Pictures()
        defer { pictures.remove() }
        let path = try pictures.quadrants()
        let (status, output) = await run(["push", "--dry-run", "--crop", "2=0,0,0.5,0.4", "--pages", "2", path],
                                         noConnection)
        #expect(status == 0, "\(output.err)")
        let image = try FrameEncoder.loadImage(url: URL(fileURLWithPath: path))
        let topLeft = FrameEncoder.encode(image, crop: Crop(left: 0, top: 0, width: 0.5, height: 0.4))
        #expect(Set(topLeft.indices()) == [4])  // all red
        #expect(output.outLines.filter { $0.hasPrefix("page ") } == [
            "page 2  CRC32 \(String(format: "%08x", topLeft.crc32))  CRC16 \(String(format: "%04x", topLeft.crc16))  "
                + "crop 0.0,0.0,0.5,0.4  \(path)",
        ])
        // probe encodes the same way; without a crop, the centre.
        let probe = await run(["probe", "--dry-run", "--crop=1=0,0,0.5,0.4", path], noConnection)
        #expect(probe.status == 0)
        #expect(probe.output.outLines.contains { $0.hasPrefix("page 1  CRC32 \(String(format: "%08x", topLeft.crc32))") })
        let centre = await run(["push", "--dry-run", path], noConnection)
        #expect(centre.output.outLines.filter { $0.hasPrefix("page ") } == [try Pictures.crcLine(page: 1, path: path)])
    }

    @Test func aCropThatDoesNotSuitThePhotoIsAUsageError() async throws {
        let pictures = try Pictures()
        defer { pictures.remove() }
        // The pictures are 80x48: under 100 px high, so only the whole picture will do.
        let (status, output) = await run(["push", "--crop", "2=0.25,0.25,0.5,0.5"] + pictures.paths.prefix(2),
                                         noConnection)
        #expect(status == 2)
        #expect(output.errLines == [
            "ulani-swift: --crop for page 2 does not fit photo2.png (80x48 px): "
                + "the crop is too small (at most 8x zoom and at least 100 photo pixels high)",
            "run 'ulani-swift --help' for usage",
        ])
        let shape = await run(["probe", "--crop", "1=0,0,1,0.5", pictures.paths[0]], noConnection)
        #expect(shape.status == 2)
        #expect(shape.output.errLines.first == "ulani-swift: --crop for page 1 does not fit photo1.png (80x48 px): "
                + "the crop must have the screen's 800:480 shape, got 80.0 x 24.0 px")
        let outside = await run(["push", "--crop", "1=0.5,0,1,1", pictures.paths[0]], noConnection)
        #expect(outside.status == 2)
        #expect(outside.output.errLines.first?.hasSuffix("(fractions 0-1), got (0.5, 0.0, 1.0, 1.0)") == true)
        // The whole picture is the centred crop: the same frame as no crop.
        let whole = await run(["push", "--dry-run", "--crop", "1=0,0,1,1", pictures.paths[0]], noConnection)
        #expect(whole.status == 0, "\(whole.output.err)")
        let frame = try Pictures.frame(pictures.paths[0])
        #expect(whole.output.outLines.contains { $0.hasPrefix("page 1  CRC32 \(String(format: "%08x", frame.crc32))") })
    }

    @Test func unreadableImageExits1() async throws {
        let (status, output) = await run(["push", "/nonexistent/missing.png"], noConnection)
        #expect(status == 1)
        #expect(output.errLines == ["error: missing.png: cannot read the file"])
    }

    @Test func usageHelpAndVersion() async {
        let (usage, bad) = await run(["push"], noConnection)
        #expect(usage == 2)
        #expect(bad.errLines == ["ulani-swift: push needs 1-4 images (one per page), got 0",
                                 "run 'ulani-swift --help' for usage"])
        let (page, badPage) = await run(["show", "5"], noConnection)
        #expect(page == 2)
        #expect(badPage.errLines == ["ulani-swift: show expects a page 1-4, got '5'",
                                     "run 'ulani-swift --help' for usage"])
        let (help, helpOutput) = await run(["--help"], noConnection)
        #expect(help == 0)
        #expect(helpOutput.out == Arguments.usage)
        let (version, versionOutput) = await run(["--version"], noConnection)
        #expect(version == 0)
        #expect(versionOutput.out == "ulani-swift \(UlaniKit.version)\n")
    }

    @Test func setupFailureExits1AfterTheRetries() async {
        let connection = Connection(attempts: 2, retryDelay: .milliseconds(10), timing: Self.timing) { _ in
            throw UlaniError.notFound
        }
        let (status, output) = await run(["info"], connection)
        #expect(status == 1)
        #expect(output.outLines.contains { $0.hasSuffix("] connecting again (attempt 2 of 2)") })
        #expect(output.errLines == ["error: \(UlaniError.connectFailed(attempts: 2, last: UlaniError.notFound.description))"])
    }

    @Test func verboseTracesTheTrafficToStderr() async throws {
        let calendar = StubCalendar()
        let (status, output) = await run(["info", "-v"], connection(calendar))
        #expect(status == 0, "\(output.err)")
        let trace = output.errLines.map { String($0.drop { $0 != "]" }.dropFirst(2)) }
        for line in ["-> command 04 4e 42  (unlock)", "<- command 04 00  (unlocked)", "-> read model number",
                     "-> command 0c 00  (status query)", "-> command 09 03  (goodbye)", "-- disconnect"] {
            #expect(trace.contains(line), "missing \(line) in\n\(output.err)")
        }
        #expect(output.outLines.contains("model      P7320E-B"))

        let (shown, show) = await run(["show", "-v", "2"], connection(calendar))
        #expect(shown == 0, "\(show.err)")
        let showTrace = show.errLines.map { String($0.drop { $0 != "]" }.dropFirst(2)) }
        for line in ["-> command 0b 02  (show page 2)", "<- command 0b 00  (page switched)"] {
            #expect(showTrace.contains(line), "missing \(line) in\n\(show.err)")
        }
    }

    @Test func flushEveryIsTheSessionReadBarrierOverBluetoothOnly() async throws {
        let pictures = try Pictures()
        defer { pictures.remove() }
        let image = pictures.paths[0]
        let bluetooth = StubCalendar()
        let (status, output) = await run(["push", "--flush-every", "100", image], connection(bluetooth))
        #expect(status == 0, "\(output.err)")
        // 230-byte chunks in groups of 100: one read between consecutive groups.
        let group = 100 * Panel.maxChunk
        #expect(bluetooth.state.firmwareReads == (Frame.byteCount + group - 1) / group - 1)

        // The relay host has its own barrier (--flush-every goes there), so the session has none.
        let relay = StubCalendar()
        #expect(await run(["push", "--relay", "h:1", "--flush-every", "100", image], connection(relay)).status == 0)
        #expect(relay.state.firmwareReads == 0)
        let plain = StubCalendar()
        #expect(await run(["push", image], connection(plain)).status == 0)
        #expect(plain.state.firmwareReads == 0)
    }

    @Test func cancelDuringSetupExits130AndDisconnectsWithoutGoodbye() async throws {
        let calendar = StubCalendar { $0.silent = [0x04] }  // never unlocks
        let (status, output) = try await cancelledRun(["info"], patientConnection(calendar)) {
            calendar.state.commands.contains { $0.first == 0x04 }
        }
        #expect(status == 130)
        #expect(output.errLines == ["interrupted"])
        #expect(!output.out.contains("setup failed"), "\(output.out)")
        #expect(calendar.state.disconnects == 1)
        #expect(!calendar.state.commands.contains(Data([0x09, 0x03])))
    }

    @Test func cancelDuringPushExits130AndDisconnectsWithoutGoodbye() async throws {
        let pictures = try Pictures()
        defer { pictures.remove() }
        let calendar = StubCalendar { $0.silent = [0x02] }  // the upload result never comes
        let (status, output) = try await cancelledRun(["push", pictures.paths[0]], patientConnection(calendar)) {
            calendar.state.imageBytes == Frame.byteCount
        }
        #expect(status == 130)
        #expect(output.errLines == ["interrupted"])
        #expect(!output.out.contains("results"))
        #expect(calendar.state.disconnects == 1)
        #expect(!calendar.state.commands.contains(Data([0x09, 0x03])))
    }

    @Test func cancelWhileLinkingIsNotReportedAsASetupFailure() async throws {
        let linking = OSAllocatedUnfairLock(initialState: false)
        let connection = Connection(attempts: 2, retryDelay: .milliseconds(10), timing: Self.timing) { _ in
            linking.withLock { $0 = true }
            try await Task.sleep(for: .seconds(60))  // throws CancellationError, like the real links
            throw UlaniError.notFound
        }
        let (status, output) = try await cancelledRun(["info", "--relay", "127.0.0.1:9"], connection) {
            linking.withLock { $0 }
        }
        #expect(status == 130)
        #expect(output.errLines == ["interrupted"])
        #expect(!output.out.contains("setup failed"), "\(output.out)")
        #expect(!output.out.contains("connecting again"), "\(output.out)")
    }

    @Test func progressBarOnATerminal() async throws {
        let pictures = try Pictures()
        defer { pictures.remove() }
        let (status, output) = await run(["push", pictures.paths[0]], connection(StubCalendar()), interactive: true)
        #expect(status == 0, "\(output.err)")
        #expect(output.err.contains("\r  [" + String(repeating: "#", count: 30) + "] 100%\n"))
        #expect(!output.out.contains("bytes ("))
    }
}

struct TimedOut: Error {}

/// Poll `condition` until it holds; fail after `timeout`.
func waitUntil(timeout: Duration = .seconds(20), _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out after \(timeout)")
            throw TimedOut()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite struct FormatTests {
    @Test func formats() {
        #expect(Format.stamp(.milliseconds(1234)) == "[   1.234]")
        #expect(Format.stamp(.seconds(125)) == "[ 125.000]")
        #expect(Format.seconds(.milliseconds(1260)) == "1.3 s")
        #expect(Format.crc32(0xBEEF) == "0000beef")
        #expect(Format.crc16(0xBE) == "00be")
        #expect(Format.pages([3, 1, 2]) == "1, 2, 3")
        #expect(Format.bar(sent: 96_000, total: 192_000) == "\r  [###############...............]  50%")
    }
}
