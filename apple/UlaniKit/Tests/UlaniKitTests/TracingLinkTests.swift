import Foundation
import os
import Testing
@testable import UlaniKit

/// `lines` contains `expected` in this order (other lines may come in between).
private func expectInOrder(_ lines: [String], _ expected: [String],
                           sourceLocation: SourceLocation = #_sourceLocation) {
    var from = lines.startIndex
    for line in expected {
        guard let i = lines[from...].firstIndex(of: line) else {
            Issue.record("missing (in order): \(line)\nlog:\n\(lines.joined(separator: "\n"))",
                         sourceLocation: sourceLocation)
            return
        }
        from = i + 1
    }
}

@Suite struct TracingLinkTests {
    @Test func annotatesCommands() throws {
        let frame = filledFrame(0x11)
        let header = try Messages.imageHeader(frameBytes: frame.bytes, page: 2)
        let crc32 = String(format: "%08x", frame.crc32), crc16 = String(format: "%04x", frame.crc16)
        func note(_ data: Data) -> String? { TracingLink.annotation(data, on: .command, outgoing: true) }
        #expect(note(header) == "image header: page 2, mode 1, 192000 bytes, crc32 \(crc32), crc16 \(crc16)")
        #expect(note(Command.unlock) == "unlock")
        #expect(note(Command.battery) == "battery query")
        #expect(note(Command.deviceInfo) == "device info query")
        #expect(note(Command.getSlot) == "status query")
        #expect(note(Command.disconnect) == "goodbye")
        #expect(note(try Messages.showSlot(page: 3)) == "show page 3")
        #expect(note(Data([0xFF, 0x00])) == nil)
        #expect(note(Data()) == nil)
    }

    @Test func annotatesReplies() {
        func note(_ bytes: [UInt8], on characteristic: GattCharacteristic = .command) -> String? {
            TracingLink.annotation(Data(bytes), on: characteristic, outgoing: false)
        }
        #expect(note([0x01, 0x00]) == "go: send the image")
        #expect(note([0x01, 0x01]) == "busy")
        #expect(note([0x01, 0x02]) == "the page already holds this image")
        #expect(note([0x02, 0x00], on: .image) == "image received")
        #expect(note([0x02, 0x01], on: .image) == "image failed")
        #expect(note([0x04, 0x00]) == "unlocked")
        #expect(note([0x04, 0x01]) == "unlock rejected")
        #expect(note([0x05, 0x00]) == "device ready")
        #expect(note([0x06, 0x04]) == "battery 4/5")
        #expect(note([0x06, 0x06]) == "charging")
        #expect(note([0x09, 0x00]) == "goodbye ok")
        #expect(note([0x0A, 0x02, 0, 0, 0, 0, 1] + Array("S1".utf8)) == "device info")
        #expect(note([0x0B, 0x00]) == "page switched")
        #expect(note([0x0C, 0x02, 0xDE, 0xAD, 0xBE, 0xEF]) == "page 2 on screen, crc32 deadbeef")
        #expect(note([0x0C, 0x01, 0x00, 0x00, 0xBE, 0xEF]) == "page 1 on screen, crc32 0000beef")
        #expect(note([0x0C, 0x02]) == nil)  // too short to parse
        #expect(note([0x77, 0x00]) == nil)
    }

    @Test func logsASessionInOrder() async throws {
        let fake = FakeLink()
        let lines = Recorder<String>()
        let link = TracingLink(fake) { lines.append($0) }
        let session = CalendarSession(link: link, timing: .test)
        try await session.start()
        #expect(try await session.firmware() == "v1.0.09")
        let frame = filledFrame(0x11)
        #expect(try await session.upload(frame, page: 2) == .ok)
        try await waitUntil { lines.values.contains("<- image 02 00  (image received)") }
        await link.disconnect()

        let header = try Messages.imageHeader(frameBytes: frame.bytes, page: 2)
        let headerHex = header.hexString(separator: " ")
        let headerNote = TracingLink.annotation(header, on: .command, outgoing: true)!
        let log = lines.values
        #expect(log.contains("<- command 05 00  (device ready)"))
        expectInOrder(log, [
            "-> command 04 4e 42  (unlock)",
            "<- command 04 00  (unlocked)",
            "-> read firmware revision",
            "<- firmware revision 76 31 2e 30 2e 30 39  (\"v1.0.09\")",
            "-> command 04 4e 42  (unlock)",
            "<- command 04 00  (unlocked)",
            "-> command \(headerHex)  (\(headerNote))",
            "<- command 01 00  (go: send the image)",
            "-- write length 244",
            "-> image 192000 bytes in 230-byte chunks",
        ])
        expectInOrder(log, ["-> image 192000 bytes in 230-byte chunks", "-- image stream sent 192000 of 192000 bytes",
                            "-- disconnect"])
        expectInOrder(log, ["-> image 192000 bytes in 230-byte chunks", "<- image 02 00  (image received)"])
        // Image chunks are summarised, not dumped.
        #expect(log.count < 20)
    }

    @Test func passesProgressAndStopsEarly() async throws {
        let fake = FakeLink { $0.greets = false }
        let lines = Recorder<String>()
        let progress = Recorder<Int>()
        let link = TracingLink(fake) { lines.append($0) }
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let sent = try await link.streamImage(Data(count: 2300), chunkSize: 230,
                                              progress: { done, _ in progress.append(done) },
                                              shouldStop: { asked.withLock { $0 += 1; return $0 > 2 } })
        #expect(sent == 460)
        #expect(progress.values == [230, 460])
        #expect(fake.imageWrites.count == 2)
        #expect(lines.values == ["-> image 2300 bytes in 230-byte chunks",
                                 "-- image stream stopped early: 460 of 2300 bytes sent"])
    }

    @Test func logsFailuresAndRethrows() async throws {
        let fake = FakeLink { $0.dead = true }
        let lines = Recorder<String>()
        let link = TracingLink(fake) { lines.append($0) }
        await #expect(throws: UlaniError.linkLost("the fake link is dead")) {
            try await link.writeCommand(Command.unlock)
        }
        await #expect(throws: UlaniError.linkLost("the fake link is dead")) {
            _ = try await link.read(.modelNumber)
        }
        #expect(lines.values.contains("!! command 04 4e 42 failed: Bluetooth link lost: the fake link is dead"))
        #expect(lines.values.contains("!! read model number failed: Bluetooth link lost: the fake link is dead"))
    }

    @Test func notificationsEndWithTheLink() async throws {
        let fake = FakeLink()
        let lines = Recorder<String>()
        let link = TracingLink(fake) { lines.append($0) }
        await link.disconnect()
        var received: [GattNotification] = []
        for await notification in link.notifications { received.append(notification) }
        #expect(received == [GattNotification(characteristic: .command, value: Reply.deviceReady)])
        #expect(fake.state.disconnects == 1)
        try await waitUntil { lines.values.last == "-- notifications ended" }
    }
}
