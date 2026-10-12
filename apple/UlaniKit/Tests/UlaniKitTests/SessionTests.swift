import Foundation
import Testing
@testable import UlaniKit

/// Session core: unlock, queries and reply matching (mirrors test_client.py's query tests).
@Suite struct SessionTests {
    @Test func startSubscribesAndUnlocksFirst() async throws {
        let link = FakeLink()
        _ = try await startedSession(link)
        #expect(link.state.subscriptions == 1)
        #expect(link.writes.first == FakeLink.Write(characteristic: .command, data: Command.unlock))
    }

    @Test func startTwiceSubscribesOnce() async throws {
        let link = FakeLink()
        let session = try await startedSession(link)
        try await session.start()
        #expect(link.state.subscriptions == 1)
        #expect(link.commandWrites == [Command.unlock, Command.unlock])
    }

    @Test func simpleQueries() async throws {
        let session = try await startedSession(FakeLink())
        #expect(try await session.battery() == Battery(level: 4, charging: false))
        let slot = try await session.currentSlot()
        #expect(slot.page == 3)
        #expect(slot.crc32 == 0xDEAD_BEEF)
        #expect(try await session.deviceInfo() == DeviceInfo(mac: "11:22:33:44:55:66", serial: "SERIAL"))
        #expect(try await session.model() == "P7320E-B")
        #expect(try await session.firmware() == "v1.0.09")
    }

    @Test func queriesWriteTheirCommands() async throws {
        let link = FakeLink()
        let session = try await startedSession(link)
        _ = try await session.battery()
        _ = try await session.currentSlot()
        _ = try await session.deviceInfo()
        #expect(link.commandWrites == [Command.unlock, Command.battery, Command.getSlot, Command.deviceInfo])
        _ = try await session.model()
        _ = try await session.firmware()
        #expect(link.log == "rr")
    }

    @Test func showSwitchesTheDisplayedPage() async throws {
        let link = FakeLink()
        try await startedSession(link).show(page: 3)
        #expect(link.commandWrites.last == Data([0x0B, 0x03]))
    }

    @Test(arguments: [0, 5])
    func showRejectsPagesOutsideOneToFour(page: Int) async throws {
        let link = FakeLink()
        let session = try await startedSession(link)
        await #expect(throws: UlaniError.self) { try await session.show(page: page) }
        #expect(link.commandWrites == [Command.unlock])
    }

    @Test func unrelatedNotificationsAreSkipped() async throws {
        // The stray "device ready" arrives AFTER the command is written and BEFORE the
        // real reply, so only the opcode filter can skip it.
        let session = try await startedSession(FakeLink { $0.stray = Reply.deviceReady })
        #expect(try await session.battery() == Battery(level: 4, charging: false))
        #expect(try await session.currentSlot().page == 3)
    }

    @Test func staleRepliesAreDrainedBeforeEachCommand() async throws {
        let link = FakeLink()
        let session = try await startedSession(link)
        link.inject(Data([0x06, 0x01]), on: .command)  // a late answer nobody waits for
        try await waitUntil { session.inbox.hasPending(.command) }
        #expect(try await session.battery() == Battery(level: 4, charging: false))
    }

    @Test func commandTimeoutIsNoReply() async throws {
        let session = try await startedSession(FakeLink { $0.silentOpcodes = [Opcode.battery] },
                                                timing: .quick())
        await #expect(throws: UlaniError.noReply(opcode: Opcode.battery)) { _ = try await session.battery() }
    }

    @Test func silentUnlockFailsStart() async throws {
        let session = CalendarSession(link: FakeLink { $0.silentOpcodes = [Opcode.unlock] }, timing: .quick())
        await #expect(throws: UlaniError.noReply(opcode: Opcode.unlock)) { try await session.start() }
    }

    @Test func rejectedUnlock() async throws {
        let session = CalendarSession(link: FakeLink { $0.unlockReply = Data([0x04, 0x01]) }, timing: .test)
        await #expect(throws: UlaniError.unlockRejected(Data([0x04, 0x01]))) { try await session.start() }
    }

    @Test func deadLinkFailsStart() async throws {
        let session = CalendarSession(link: FakeLink { $0.dead = true }, timing: .test)
        await #expect(throws: UlaniError.linkLost("the fake link is dead")) { try await session.start() }
    }

    @Test func lostLinkEndsAWaitEarly() async throws {
        // When the notifications end (link gone) a pending command fails at once instead
        // of waiting out its reply timeout.
        let link = FakeLink { $0.silentOpcodes = [Opcode.battery] }
        let session = try await startedSession(link, timing: SessionTiming(replyTimeout: .seconds(30)))
        let clock = ContinuousClock()
        let started = clock.now
        let battery = Task { try await session.battery() }
        try await waitUntil { link.commandWrites.contains(Command.battery) }
        await link.disconnect()
        await #expect(throws: UlaniError.linkLost("the device disconnected")) { _ = try await battery.value }
        #expect(clock.now - started < .seconds(10))
    }
}

@Suite struct ReplyInboxTests {
    @Test func returnsTheFirstValueWithTheOpcodeAndDropsTheOthers() async throws {
        let inbox = ReplyInbox()
        await inbox.deliver(GattNotification(characteristic: .command, value: Data([0x05, 0x00])))
        await inbox.deliver(GattNotification(characteristic: .command, value: Data()))
        await inbox.deliver(GattNotification(characteristic: .command, value: Data([0x06, 0x02])))
        await inbox.deliver(GattNotification(characteristic: .command, value: Data([0x06, 0x03])))
        let reply = try await inbox.next(on: .command, opcode: 0x06, timeout: .seconds(1))
        #expect(reply == Data([0x06, 0x02]))
        #expect(inbox.hasPending(.command))
        #expect(try await inbox.next(on: .command, opcode: 0x06, timeout: .seconds(1)) == Data([0x06, 0x03]))
        #expect(!inbox.hasPending(.command))
    }

    @Test func aWaiterGetsALaterValueAndSkipsOthers() async throws {
        let inbox = ReplyInbox()
        let reply = Task { try await inbox.next(on: .image, opcode: 0x02, timeout: .seconds(2)) }
        try await Task.sleep(for: .milliseconds(20))
        await inbox.deliver(GattNotification(characteristic: .command, value: Data([0x02, 0x01])))
        await inbox.deliver(GattNotification(characteristic: .image, value: Data([0x05, 0x00])))
        await inbox.deliver(GattNotification(characteristic: .image, value: Data([0x02, 0x00])))
        #expect(try await reply.value == Data([0x02, 0x00]))
        // The command value went to its own buffer; the skipped image value is gone.
        #expect(inbox.hasPending(.command))
        #expect(!inbox.hasPending(.image))
    }

    @Test func timeoutIsNoReply() async throws {
        let inbox = ReplyInbox()
        await inbox.deliver(GattNotification(characteristic: .command, value: Data([0x05, 0x00])))
        await #expect(throws: UlaniError.noReply(opcode: 0x0C)) {
            _ = try await inbox.next(on: .command, opcode: 0x0C, timeout: .milliseconds(30))
        }
        #expect(!inbox.hasPending(.command))
    }

    @Test func drainEmptiesOneCharacteristic() async throws {
        let inbox = ReplyInbox()
        await inbox.deliver(GattNotification(characteristic: .command, value: Data([0x04, 0x00])))
        await inbox.deliver(GattNotification(characteristic: .image, value: Data([0x02, 0x00])))
        await inbox.drain(.image)
        #expect(!inbox.hasPending(.image))
        #expect(inbox.hasPending(.command))
        await inbox.drain(.command)
        #expect(!inbox.hasPending(.command))
    }

    @Test func closeFailsWaitersAndLaterCalls() async throws {
        let inbox = ReplyInbox()
        let reply = Task { try await inbox.next(on: .command, opcode: 0x04, timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(20))
        await inbox.close(reason: "gone")
        await #expect(throws: UlaniError.linkLost("gone")) { _ = try await reply.value }
        await #expect(throws: UlaniError.linkLost("gone")) {
            _ = try await inbox.next(on: .command, opcode: 0x04, timeout: .seconds(30))
        }
    }

    @Test func cancellationEndsTheWait() async throws {
        let inbox = ReplyInbox()
        let task = Task { try await inbox.next(on: .command, opcode: 0x04, timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
