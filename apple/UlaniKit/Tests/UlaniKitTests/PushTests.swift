import Foundation
import os
import Testing
@testable import UlaniKit

/// Collects values from `@Sendable` callbacks.
final class Recorder<Value: Sendable>: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Value]())
    func append(_ value: Value) { lock.withLock { $0.append(value) } }
    var values: [Value] { lock.withLock { $0 } }
}

private let total = Frame.byteCount
/// Chunks of a frame at the default write length (244 -> 230-byte chunks).
private let chunkCount = (Frame.byteCount + 229) / 230  // 835

/// Upload, push, probe and goodbye (every upload/push test of python/tests/test_client.py).
@Suite struct UploadTests {
    @Test func happyPath() async throws {
        let link = FakeLink { $0.writeLength = 100 }
        let frame = patternFrame()
        let progress = Recorder<[Int]>()
        let session = try await startedSession(link)
        let result = try await session.upload(frame, page: 2) { sent, total in progress.append([sent, total]) }
        #expect(result == .ok)
        #expect(link.headers == [try Messages.imageHeader(frameBytes: frame.bytes, page: 2)])
        // unlock (start), then unlock + header for the page
        #expect(link.commandWrites.map { $0.first } == [Opcode.unlock, Opcode.unlock, Opcode.imageHeader])
        let chunks = link.imageWrites
        #expect(chunks.reduce(Data(), +) == frame.bytes)
        #expect(chunks.map(\.count).max() == 100)
        #expect(progress.values.last == [total, total])
        #expect(progress.values.count == chunks.count)
    }

    @Test(arguments: [
        (10, String(repeating: "wwwwwwwwwwr", count: 83) + "wwwww"),
        (5, String(repeating: "wwwwwr", count: 166) + "wwwww"),    // no read after the last chunk
        (3, String(repeating: "wwwr", count: 278) + "w"),
    ])
    func readBarrierForFlowControl(every: Int, expected: String) async throws {
        // Windows queues write-without-response and most likely drops on overflow; a GATT
        // read every N packets waits until the queue has drained.
        let link = FakeLink()
        let frame = patternFrame()
        let progress = Recorder<Int>()
        let session = try await startedSession(link, readBarrierEvery: every)
        #expect(try await session.upload(frame, page: 1) { sent, _ in progress.append(sent) } == .ok)
        #expect(link.log == expected)
        #expect(link.imageWrites.reduce(Data(), +) == frame.bytes)
        #expect(progress.values == (1...chunkCount).map { min($0 * 230, total) })
    }

    @Test(arguments: [nil, 0] as [Int?])
    func noReadBarrierUnlessAsked(every: Int?) async throws {
        let link = FakeLink()
        let session = try await startedSession(link, readBarrierEvery: every)
        #expect(try await session.upload(filledFrame(1), page: 1) == .ok)
        #expect(!link.log.contains("r"))
        #expect(link.log.count == chunkCount)
    }

    @Test func sameImageSendsNoData() async throws {
        let link = FakeLink { $0.headerReply = Reply.headerSameImage }
        #expect(try await startedSession(link).upload(filledFrame(0x11), page: 1) == .unchanged)
        #expect(link.imageWrites.isEmpty)
    }

    @Test func storedImageIsUnchanged() async throws {
        let frame = filledFrame(0x22)
        let link = FakeLink { $0.storedCRC = [3: frame.crc32] }
        #expect(try await startedSession(link).upload(frame, page: 3) == .unchanged)
        #expect(link.imageWrites.isEmpty)
    }

    @Test func busyUntilTheDeadlineIsDeviceBusy() async throws {
        let link = FakeLink { $0.headerReply = Reply.headerBusy }
        let session = try await startedSession(link, timing: .quick(busy: .milliseconds(200)))
        await #expect(throws: UlaniError.deviceBusy(what: "an image for page 1")) {
            _ = try await session.upload(filledFrame(0x11), page: 1)
        }
        #expect(!link.headers.isEmpty)
        #expect(link.imageWrites.isEmpty)
    }

    @Test func dataFailure() async throws {
        let session = try await startedSession(FakeLink { $0.dataReply = Reply.dataFail })
        await #expect(throws: UlaniError.uploadFailed(page: 1, reply: Reply.dataFail)) {
            _ = try await session.upload(filledFrame(0x11), page: 1)
        }
    }

    @Test func unexpectedHeaderReply() async throws {
        let session = try await startedSession(FakeLink { $0.headerReply = Data([0x01, 0x05]) })
        await #expect(throws: UlaniError.unexpectedHeaderReply(page: 4, reply: Data([0x01, 0x05]))) {
            _ = try await session.upload(filledFrame(0x11), page: 4)
        }
    }

    @Test(arguments: [(20, 20), (97, 97), (230, 230), (244, 230), (517, 230), (19, 20), (0, 20)])
    func chunkSizeFollowsTheWriteLength(writeLength: Int, expected: Int) async throws {
        #expect(CalendarSession.chunkSize(forWriteLength: writeLength) == expected)
        let link = FakeLink { $0.writeLength = writeLength }
        #expect(try await startedSession(link).upload(filledFrame(3), page: 1) == .ok)
        #expect(link.imageWrites.map(\.count).max() == expected)
    }

    @Test func unrelatedNotificationsAreSkipped() async throws {
        let link = FakeLink { $0.stray = Reply.deviceReady }
        let session = try await startedSession(link)
        #expect(try await session.battery().level == 4)
        #expect(try await session.upload(filledFrame(0x33), page: 1) == .ok)
    }

    @Test(arguments: [true, false])
    func waitsWhileThePanelIsRefreshing(silent: Bool) async throws {
        let link = FakeLink { if silent { $0.silentHeaders = 3 } else { $0.busyHeaders = 3 } }
        // Each ignored header costs a reply timeout; one long enough that the accepted
        // header's answer cannot miss it on a loaded machine (that would add an attempt).
        let session = try await startedSession(link, timing: .quick(reply: silent ? .milliseconds(250) : .seconds(2)))
        #expect(try await session.upload(filledFrame(0x44), page: 1) == .ok)
        #expect(link.headers.count == 4)  // 3 ignored/busy + 1 accepted
        #expect(link.state.headerPages == [1])
        #expect(link.state.received == total)
    }

    @Test func givesUpWhenTheDeviceStaysSilent() async throws {
        let link = FakeLink { $0.silentHeaders = 10_000 }
        let session = try await startedSession(link, timing: .quick(busy: .milliseconds(300)))
        await #expect(throws: UlaniError.deviceBusy(what: "an image for page 1")) {
            _ = try await session.upload(filledFrame(0x44), page: 1)
        }
    }

    @Test func stopsStreamingWhenTheDeviceGivesUp() async throws {
        let link = FakeLink { $0.failAfterPackets = 5 }
        let session = try await startedSession(link)
        await #expect(throws: UlaniError.uploadFailed(page: 1, reply: Reply.dataFail)) {
            _ = try await session.upload(filledFrame(0x55), page: 1)
        }
        #expect(link.state.packets >= 5)
        #expect(link.state.packets < 50)  // Python: < 10; room for scheduler jitter
    }

    @Test func stopsStreamingWhenTheDeviceGivesUpWithReadBarriers() async throws {
        let link = FakeLink { $0.failAfterPackets = 5 }
        let session = try await startedSession(link, readBarrierEvery: 10)
        await #expect(throws: UlaniError.uploadFailed(page: 1, reply: Reply.dataFail)) {
            _ = try await session.upload(filledFrame(0x55), page: 1)
        }
        #expect(link.state.packets < 50)
    }

    @Test func staleImageRepliesAreDrainedBeforeStreaming() async throws {
        // A late 02 00 from earlier must neither stop the stream nor count as the result.
        let link = FakeLink { $0.dataReply = Reply.dataFail }
        let session = try await startedSession(link)
        link.inject(Reply.dataOK, on: .image)
        try await waitUntil { session.inbox.hasPending(.image) }
        await #expect(throws: UlaniError.uploadFailed(page: 1, reply: Reply.dataFail)) {
            _ = try await session.upload(filledFrame(0x66), page: 1)
        }
        #expect(link.imageWrites.count == chunkCount)
    }
}

@Suite struct PushTests {
    @Test(arguments: [
        (2, [1, 2, 3, 4], [1, 3, 4, 2]),  // page on screen goes last
        (4, [2, 4], [2, 4]),
        (3, [4, 1], [1, 4]),              // shown page not among them: ascending
        (1, [1], [1]),
    ])
    func uploadsTheShownPageLast(shown: Int, pages: [Int], order: [Int]) async throws {
        let link = FakeLink { $0.shown = shown }
        let session = try await startedSession(link)
        let frames = Dictionary(uniqueKeysWithValues: pages.map { ($0, filledFrame(UInt8($0))) })
        let results = try await session.push(frames)
        #expect(link.state.headerPages == order)
        #expect(results == Dictionary(uniqueKeysWithValues: pages.map { ($0, UploadResult.ok) }))
    }

    @Test func unlocksBeforeEveryHeader() async throws {
        let link = FakeLink { $0.shown = 4 }
        let session = try await startedSession(link)
        _ = try await session.push([1: filledFrame(1), 2: filledFrame(2)])
        #expect(link.commandWrites.map { $0.first } == [
            Opcode.unlock, Opcode.getSlot,
            Opcode.unlock, Opcode.imageHeader,
            Opcode.unlock, Opcode.imageHeader,
        ])
    }

    @Test func reportsProgressPerPage() async throws {
        let link = FakeLink { $0.shown = 2 }
        let events = Recorder<PushEvent>()
        let session = try await startedSession(link)
        _ = try await session.push([1: filledFrame(1), 2: filledFrame(2)]) { events.append($0) }

        func page(_ page: Int, _ index: Int) -> [PushEvent] {
            [PushEvent(page: page, phase: .start, index: index, count: 2, sent: 0, total: total)]
                + (1...chunkCount).map {
                    PushEvent(page: page, phase: .sending, index: index, count: 2,
                              sent: min($0 * 230, total), total: total)
                }
                + [PushEvent(page: page, phase: .done, index: index, count: 2, sent: total, total: total)]
        }
        let expected = page(1, 0) + page(2, 1)
            + [PushEvent(page: 2, phase: .refreshing, index: 1, count: 2, sent: total, total: total)]
        #expect(events.values == expected)
    }

    @Test func unchangedPagesReportUnchangedAndNoRefresh() async throws {
        let frames = [1: filledFrame(1), 2: filledFrame(2)]
        let link = FakeLink { $0.shown = 2; $0.storedCRC = [2: frames[2]!.crc32] }
        let events = Recorder<PushEvent>()
        let session = try await startedSession(link)
        let results = try await session.push(frames) { events.append($0) }
        #expect(results == [1: .ok, 2: .unchanged])
        let phases = events.values.filter { $0.phase != .sending }.map { "\($0.page) \($0.phase.rawValue)" }
        #expect(phases == ["1 start", "1 done", "2 start", "2 unchanged"])
        await session.sayGoodbye()
        #expect(link.commandWrites.last == Command.disconnect)
    }

    @Test func pushingTheSameFramesAgainChangesNothing() async throws {
        let link = FakeLink { $0.shown = 1 }
        let session = try await startedSession(link)
        let frames = [1: filledFrame(1), 3: filledFrame(3)]
        #expect(try await session.push(frames) == [1: .ok, 3: .ok])
        let written = link.imageWrites.count
        #expect(try await session.push(frames) == [1: .unchanged, 3: .unchanged])
        #expect(link.imageWrites.count == written)
    }

    @Test func goodbyeIsSkippedWhileThePanelRefreshes() async throws {
        let link = FakeLink { $0.shown = 2; $0.refreshSilence = true }
        let session = try await startedSession(link, timing: SessionTiming(replyTimeout: .seconds(2)))
        _ = try await session.push([1: filledFrame(1), 2: filledFrame(2)])
        let elapsed = await ContinuousClock().measure { await session.sayGoodbye() }
        #expect(elapsed < .seconds(1))  // no wait for an answer that cannot come
        #expect(!link.commandWrites.contains(Command.disconnect))
    }

    @Test func goodbyeIsSentWhenThePanelIsNotRefreshing() async throws {
        let link = FakeLink { $0.shown = 2; $0.refreshSilence = true }
        let session = try await startedSession(link)
        _ = try await session.push([1: filledFrame(1)])  // page 2 stays on screen: no refresh
        await session.sayGoodbye()
        #expect(link.commandWrites.last == Command.disconnect)
    }

    @Test func goodbyeIsBestEffortOnADeadLink() async throws {
        let link = FakeLink()
        let session = try await startedSession(link)
        link.update { $0.dead = true }
        await session.sayGoodbye()  // must not throw or hang
        #expect(!link.commandWrites.contains(Command.disconnect))
    }

    @Test func failureNamesThePageAndKeepsEarlierResults() async throws {
        let link = FakeLink { $0.shown = 4; $0.failPages = [2] }
        let session = try await startedSession(link)
        let frames = Dictionary(uniqueKeysWithValues: (1...4).map { ($0, filledFrame(UInt8($0))) })
        await #expect(throws: PushError(page: 2, completed: [1: .ok],
                                        underlying: .uploadFailed(page: 2, reply: Reply.dataFail))) {
            _ = try await session.push(frames)
        }
        #expect(link.state.headerPages == [1, 2])  // stops at the first failure
    }

    @Test func pushErrorMessageStartsWithThePage() {
        let busy = PushError(page: 3, completed: [:], underlying: .deviceBusy(what: "an image for page 3"))
        #expect(busy.description.hasPrefix("page 3: the device did not accept"))
        let failed = PushError(page: 2, completed: [:], underlying: .uploadFailed(page: 2, reply: Reply.dataFail))
        #expect(failed.description == "page 2: device reported failure: 02 01")
    }

    @Test func ulaniErrorFromUnwrapsPushErrors() {
        let busy = UlaniError.deviceBusy(what: "an image for page 3")
        #expect(UlaniError.from(busy) == busy)
        #expect(UlaniError.from(PushError(page: 3, completed: [1: .ok], underlying: busy)) == busy)
        #expect(UlaniError.from(CancellationError()) == nil)
        #expect(UlaniError.from(FakeLinkBug()) == nil)
    }

    @Test func dataFailureMidStreamStopsThePush() async throws {
        // 02 01 after the 5th packet of page 2: streaming stops early, page 1 stays done.
        let link = FakeLink { $0.shown = 4; $0.failAfterPackets = chunkCount + 5 }
        let session = try await startedSession(link)
        await #expect(throws: PushError(page: 2, completed: [1: .ok],
                                        underlying: .uploadFailed(page: 2, reply: Reply.dataFail))) {
            _ = try await session.push([1: filledFrame(1), 2: filledFrame(2), 3: filledFrame(3)])
        }
        #expect(link.state.packets - chunkCount < 50)
        #expect(link.state.headerPages == [1, 2])
    }

    @Test func silenceLongerThanTheBusyTimeoutAbortsThePush() async throws {
        // One silent attempt (1 s) outlasts the busy timeout; the other replies have a
        // whole second to arrive even on a loaded machine.
        let link = FakeLink { $0.shown = 4; $0.silentPages = [2] }
        let timing = SessionTiming(replyTimeout: .seconds(1), resultTimeout: .seconds(2),
                                   busyTimeout: .milliseconds(500), retryDelay: .milliseconds(10))
        let session = try await startedSession(link, timing: timing)
        await #expect(throws: PushError(page: 2, completed: [1: .ok],
                                        underlying: .deviceBusy(what: "an image for page 2"))) {
            _ = try await session.push([1: filledFrame(1), 2: filledFrame(2), 3: filledFrame(3)])
        }
        #expect(!link.headers.contains { $0[5] == 3 })  // the remaining page was not sent
    }

    @Test func busyLongerThanTheBusyTimeoutAbortsThePush() async throws {
        // Busy replies come back at once, so a 2 s busy timeout leaves room for several
        // retries even when parallel CPU-heavy tests delay this one's tasks.
        let link = FakeLink { $0.shown = 4; $0.busyPages = [2] }
        let timing = SessionTiming(replyTimeout: .seconds(2), resultTimeout: .seconds(2),
                                   busyTimeout: .seconds(2), retryDelay: .milliseconds(10))
        let session = try await startedSession(link, timing: timing)
        await #expect(throws: PushError(page: 2, completed: [1: .ok],
                                        underlying: .deviceBusy(what: "an image for page 2"))) {
            _ = try await session.push([1: filledFrame(1), 2: filledFrame(2), 3: filledFrame(3)])
        }
        #expect(link.headers.filter { $0[5] == 2 }.count > 1)  // page 2 was retried
        #expect(!link.headers.contains { $0[5] == 3 })
        #expect(link.state.headerPages == [1])
    }

    @Test func unexpectedHeaderReplyAbortsThePush() async throws {
        let link = FakeLink { $0.headerReply = Data([0x01, 0x07]) }
        let session = try await startedSession(link)
        await #expect(throws: PushError(page: 1, completed: [:],
                                        underlying: .unexpectedHeaderReply(page: 1, reply: Data([0x01, 0x07])))) {
            _ = try await session.push([1: filledFrame(1), 2: filledFrame(2)])
        }
        #expect(link.headers.count == 1)
    }

    @Test func statusQueryIsRetriedWhileSilent() async throws {
        let link = FakeLink { $0.silentSlotQueries = 2 }
        let session = try await startedSession(link, timing: .quick())
        #expect(try await session.push([1: filledFrame(1)]) == [1: .ok])
        #expect(link.commandWrites.filter { $0 == Command.getSlot }.count >= 3)
    }

    @Test func silentStatusQueryIsDeviceBusy() async throws {
        let link = FakeLink { $0.silentOpcodes = [Opcode.getSlot] }
        let session = try await startedSession(link, timing: .quick(busy: .milliseconds(200)))
        await #expect(throws: UlaniError.deviceBusy(what: "a status query")) {
            _ = try await session.push([1: filledFrame(1)])
        }
        #expect(link.headers.isEmpty)
    }

    @Test(arguments: [0, 5, 16])
    func rejectsPagesOutsideOneToFour(page: Int) async throws {
        let link = FakeLink()
        let session = try await startedSession(link)
        await #expect(throws: UlaniError.self) {
            _ = try await session.push([1: filledFrame(1), page: filledFrame(2)])
        }
        await #expect(throws: UlaniError.self) { _ = try await session.push([1: filledFrame(1)], show: page) }
        #expect(link.commandWrites == [Command.unlock])  // nothing written after start
    }

    @Test(arguments: [nil, 10] as [Int?])
    func cancellingStopsTheStreamAndSkipsTheGoodbye(readBarrierEvery: Int?) async throws {
        // Python's upload is cancelled at the sleep(0) before each chunk. A link streams
        // until `shouldStop`, so without it a cancelled push would send the whole frame
        // (~30 s on hardware), succeed and even say goodbye.
        // 5 ms per chunk: the whole frame would take over 4 s, so the cancel lands mid-stream.
        let link = FakeLink { $0.chunkDelay = .milliseconds(5) }
        let connector = CalendarConnector(retryDelay: .milliseconds(5), timing: .test,
                                          readBarrierEvery: readBarrierEvery, makeLink: { link })
        let task = Task { try await connector.withCalendar { try await $0.push([1: filledFrame(1)]) } }
        try await waitUntil(timeout: .seconds(20)) { link.state.packets >= 5 }
        let atCancel = link.state.packets
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(link.state.packets - atCancel < 20)
        #expect(!link.commandWrites.contains(Command.disconnect))  // no goodbye
        #expect(link.state.disconnects == 1)
    }

    @Test func deadLinkFailsThePush() async throws {
        let link = FakeLink()
        let session = try await startedSession(link)
        link.update { $0.dead = true }
        await #expect(throws: UlaniError.linkLost("the fake link is dead")) {
            _ = try await session.push([1: filledFrame(1)])
        }
    }
}

/// push(show:): switch the display in the same connection (shared/BOARD.md; the
/// push_pages(show=...) tests of python/tests/test_client.py).
@Suite struct SwitchingPushTests {
    @Test(arguments: [
        // every page except the one on screen, then the switch, then the page that was on screen
        (2, [1, 2, 3, 4], 4, ["header 1", "header 3", "header 4", "show 4", "header 2"]),
        (1, [1, 4], 4, ["header 4", "show 4", "header 1"]),
        // the page on screen is not being replaced: switch at the end
        (3, [1, 4], 4, ["header 1", "header 4", "show 4"]),
        // the page to show is not in this push: it is shown anyway
        (2, [1], 3, ["header 1", "show 3"]),
        (2, [2], 3, ["show 3", "header 2"]),
    ])
    func switchesTheDisplayWithOneRefresh(shown: Int, pages: [Int], show: Int, steps: [String]) async throws {
        // The device ignores 3 commands while it refreshes; the page that was on screen waits.
        let link = FakeLink { $0.shown = shown; $0.quietAfterRefresh = 3 }
        let session = try await startedSession(link, timing: .quick(reply: .milliseconds(250)))
        let frames = Dictionary(uniqueKeysWithValues: pages.map { ($0, filledFrame(UInt8($0))) })
        let results = try await session.push(frames, show: show)
        #expect(link.state.steps == steps)
        #expect(link.state.refreshes == 1 && link.state.shown == show)
        #expect(results == Dictionary(uniqueKeysWithValues: pages.map { ($0, UploadResult.ok) }))
    }

    @Test func anUnchangedPageToShowIsStillSwitchedTo() async throws {
        let frames = [3: filledFrame(3), 4: filledFrame(4)]
        let link = FakeLink { $0.shown = 1; $0.storedCRC = [4: frames[4]!.crc32] }
        let session = try await startedSession(link)
        #expect(try await session.push(frames, show: 4) == [3: .ok, 4: .unchanged])
        #expect(link.state.steps == ["header 3", "header 4", "show 4"])
        #expect(link.state.refreshes == 1)
    }

    @Test(arguments: [2, nil] as [Int?])
    func showingThePageOnScreenIsTheUsualPush(show: Int?) async throws {
        let link = FakeLink { $0.shown = 2 }
        let events = Recorder<PushEvent>()
        let session = try await startedSession(link)
        _ = try await session.push([1: filledFrame(1), 2: filledFrame(2)], show: show) { events.append($0) }
        #expect(link.state.steps == ["header 1", "header 2"])
        #expect(link.state.refreshes == 1)  // replacing page 2 refreshes the panel
        #expect(events.values.map(\.phase).filter { $0 != .sending }.suffix(2) == [.done, .refreshing])
    }

    @Test func switchingIsReportedAsItsOwnStep() async throws {
        let link = FakeLink { $0.shown = 2 }
        let events = Recorder<PushEvent>()
        let session = try await startedSession(link)
        let frames = [1: filledFrame(1), 2: filledFrame(2), 3: filledFrame(3)]
        _ = try await session.push(frames, show: 3) { events.append($0) }
        let phases = events.values.filter { $0.phase != .sending }.map { "\($0.page) \($0.phase.rawValue)" }
        // page 2 is no longer on screen: no "refreshing"
        #expect(phases == ["1 start", "1 done", "3 start", "3 done", "3 switching", "2 start", "2 done"])
        #expect(events.values.first { $0.phase == .switching } == PushEvent(page: 3, phase: .switching, index: 2, count: 3))
    }

    @Test func goodbyeIsSkippedAfterSwitching() async throws {
        let link = FakeLink { $0.shown = 2 }
        let session = try await startedSession(link)
        _ = try await session.push([1: filledFrame(1)], show: 1)
        await session.sayGoodbye()
        #expect(!link.commandWrites.contains(Command.disconnect))
    }

    @Test func aRejectedSwitchNamesThePageAndKeepsTheResults() async throws {
        let link = FakeLink { $0.shown = 2; $0.showReply = Data([0x0B, 0x01]) }
        let session = try await startedSession(link)
        let frames = [1: filledFrame(1), 2: filledFrame(2), 4: filledFrame(4)]
        await #expect(throws: PushError(page: 4, completed: [1: .ok, 4: .ok],
                                        underlying: .protocolError("switching the display was rejected: 0b 01"))) {
            _ = try await session.push(frames, show: 4)
        }
        #expect(link.state.headerPages == [1, 4])  // the page on screen was not touched
    }
}

@Suite struct ProbeTests {
    @Test func matchingPageWritesOnlyTheHeader() async throws {
        let frame = filledFrame(0x12)
        let link = FakeLink { $0.storedCRC = [2: frame.crc32] }
        let session = try await startedSession(link)
        #expect(try await session.probe(page: 2, frame: frame) == .matches)
        #expect(link.commandWrites == [Command.unlock, Command.unlock,
                                       try Messages.imageHeader(frameBytes: frame.bytes, page: 2)])
        #expect(link.imageWrites.isEmpty)
    }

    @Test func otherPageDiffersAfterTheDeviceGivesUp() async throws {
        let link = FakeLink { $0.storedCRC = [2: 0x1234_5678]; $0.dataStartTimeout = .milliseconds(100) }
        let session = try await startedSession(link)
        #expect(try await session.probe(page: 2, frame: filledFrame(0x12)) == .differs)
        #expect(link.imageWrites.isEmpty)
        #expect(link.headers.count == 1)
    }

    @Test func otherPageDiffersEvenWhenTheDeviceNeverGivesUp() async throws {
        // `01 00` already says the page differs; the `02 01` give-up was seen only once on
        // hardware, so its absence must not turn the answer into an error.
        let link = FakeLink { $0.storedCRC = [2: 0x1234_5678]; $0.dataStartTimeout = nil }
        let session = try await startedSession(link, timing: .quick(reply: .seconds(2), result: .milliseconds(300)))
        #expect(try await session.probe(page: 2, frame: filledFrame(0x12)) == .differs)
        #expect(link.imageWrites.isEmpty)
        #expect(try await session.battery().level == 4)  // the session still works
    }

    @Test func giveUpWaitIsShorterThanTheResultTimeout() {
        // Defaults: 5 s reply + 5 s for the ~4 s give-up, not the 90 s an upload may take.
        #expect(CalendarSession.probeGiveUpWait(SessionTiming()) == .seconds(10))
        #expect(CalendarSession.probeGiveUpWait(.quick(reply: .seconds(2), result: .milliseconds(300)))
            == .milliseconds(300))
    }

    @Test func pushedPagesMatch() async throws {
        let link = FakeLink { $0.shown = 1 }
        let session = try await startedSession(link)
        let frames = [1: filledFrame(1), 2: filledFrame(2)]
        _ = try await session.push(frames)
        link.update { $0.dataStartTimeout = .milliseconds(100) }
        #expect(try await session.probe(page: 1, frame: frames[1]!) == .matches)
        #expect(try await session.probe(page: 2, frame: frames[2]!) == .matches)
        #expect(try await session.probe(page: 2, frame: frames[1]!) == .differs)
    }

    @Test func probeWaitsWhileSilent() async throws {
        let frame = filledFrame(0x12)
        let link = FakeLink { $0.storedCRC = [1: frame.crc32]; $0.silentHeaders = 2 }
        let session = try await startedSession(link, timing: .quick())
        #expect(try await session.probe(page: 1, frame: frame) == .matches)
        #expect(link.headers.count >= 3)
    }

    @Test(arguments: [0, 5])
    func rejectsPagesOutsideOneToFour(page: Int) async throws {
        let link = FakeLink()
        let session = try await startedSession(link)
        await #expect(throws: UlaniError.self) { _ = try await session.probe(page: page, frame: filledFrame(1)) }
        #expect(link.commandWrites == [Command.unlock])
    }
}
