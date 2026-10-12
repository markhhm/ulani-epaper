import Foundation
import Testing
@testable import UlaniKit

@Suite struct MessageTests {
    // MARK: parsers reject wrong opcodes and short input

    @Test func batteryRejectsWrongOpcodeAndShortInput() throws {
        let wrong = protocolErrorMessage { _ = try Messages.parseBattery(fromHex("0c00")) }
        #expect(wrong?.contains("expected opcode 0x06") == true)
        #expect(wrong?.contains("0c 00") == true)
        #expect(protocolErrorMessage { _ = try Messages.parseBattery(fromHex("06")) } != nil)
        #expect(protocolErrorMessage { _ = try Messages.parseBattery(Data()) } != nil)
    }

    @Test func slotRejectsWrongOpcodeAndShortInput() throws {
        #expect(protocolErrorMessage { _ = try Messages.parseSlot(fromHex("06022b9f7a43")) } != nil)
        #expect(protocolErrorMessage { _ = try Messages.parseSlot(fromHex("0c022b9f7a")) } != nil)
        #expect(protocolErrorMessage { _ = try Messages.parseSlot(Data()) } != nil)
    }

    @Test func deviceInfoRejectsWrongOpcodeAndShortInput() throws {
        #expect(protocolErrorMessage { _ = try Messages.parseDeviceInfo(fromHex("0b112233445566")) } != nil)
        #expect(protocolErrorMessage { _ = try Messages.parseDeviceInfo(fromHex("0a1122334455")) } != nil)
    }

    @Test func parsersAcceptSlices() throws {
        let padded = try fromHex("ff0c022b9f7a43")
        let slot = try Messages.parseSlot(padded[1...])
        #expect(slot.page == 2)
        #expect(slot.crc32 == 0x2B9F_7A43)
    }

    @Test func deviceInfoWithoutSerialAndWithNonASCII() throws {
        let bare = try Messages.parseDeviceInfo(fromHex("0aa1b2c3d4e5f6"))
        #expect(bare == DeviceInfo(mac: "A1:B2:C3:D4:E5:F6", serial: ""))
        // Like Python's decode("ascii", errors="replace"): one U+FFFD per bad byte.
        let odd = try Messages.parseDeviceInfo(fromHex("0a112233445566" + "41ff42"))
        #expect(odd.serial == "A\u{FFFD}B")
    }

    @Test func batteryLevelPassesThrough() throws {
        #expect(try Messages.parseBattery(fromHex("0601")) == Battery(level: 1, charging: false))
    }

    // MARK: builders

    @Test func imageHeaderRejectsOutOfRangeSlotAndMode() {
        let data = Data([1, 2, 3])
        #expect(protocolErrorMessage { _ = try Messages.imageHeader(frameBytes: data, page: 256) } != nil)
        #expect(protocolErrorMessage { _ = try Messages.imageHeader(frameBytes: data, page: -1) } != nil)
        #expect(protocolErrorMessage { _ = try Messages.imageHeader(frameBytes: data, page: 1, mode: 256) } != nil)
        #expect(protocolErrorMessage { _ = try Messages.imageHeader(frameBytes: data, page: 1, mode: -1) } != nil)
        #expect(throws: Never.self) { _ = try Messages.imageHeader(frameBytes: data, page: 255, mode: 255) }
        #expect(throws: Never.self) { _ = try Messages.imageHeader(frameBytes: data, page: 0, mode: 0) }
    }

    @Test func imageHeaderDefaultsToModeOne() throws {
        let header = try Messages.imageHeader(frameBytes: Data("123456789".utf8), page: 2)
        #expect(toHex(header) == "01000000090201cbf4392631c3")
    }

    @Test func showSlotAcceptsOneToFourOnly() throws {
        for page in 1...4 {
            #expect(try Messages.showSlot(page: page) == Data([0x0B, UInt8(page)]))
        }
        for page in [0, 5, 16, -1] {
            #expect(protocolErrorMessage { _ = try Messages.showSlot(page: page) } != nil, "page \(page)")
        }
    }

    @Test func chunksOfAFrame() throws {
        let frame = Data((0..<Panel.frameBytes).map { UInt8(truncatingIfNeeded: $0) })
        let parts = try Messages.chunks(frame, size: 230)
        #expect(parts.count == 835)
        #expect(parts.last?.count == 180)
        #expect(parts.dropLast().allSatisfy { $0.count == 230 })
        #expect(parts.allSatisfy { $0.startIndex == 0 })
        #expect(Data(parts.joined()) == frame)
    }

    @Test func chunksEdgeCases() throws {
        #expect(try Messages.chunks(Data(), size: 230).isEmpty)
        #expect(try Messages.chunks(Data([1, 2, 3]), size: 2) == [Data([1, 2]), Data([3])])
        #expect(protocolErrorMessage { _ = try Messages.chunks(Data([1]), size: 0) } != nil)
        #expect(protocolErrorMessage { _ = try Messages.chunks(Data([1]), size: -1) } != nil)
        // Like Python: a size beyond the data gives one chunk, also for a slice
        // (startIndex > 0), where start + size would overflow.
        #expect(try Messages.chunks(Data([1, 2, 3]), size: .max) == [Data([1, 2, 3])])
        let slice = Data([0, 1, 2, 3, 4])[1...]
        #expect(try Messages.chunks(slice, size: .max) == [Data([1, 2, 3, 4])])
        let parts = try Messages.chunks(slice, size: 3)
        #expect(parts == [Data([1, 2, 3]), Data([4])])
        #expect(parts.allSatisfy { $0.startIndex == 0 })
    }
}
