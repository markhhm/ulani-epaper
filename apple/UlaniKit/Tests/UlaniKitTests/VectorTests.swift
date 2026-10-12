import Foundation
import Testing
@testable import UlaniKit

/// Every entry of shared/vectors/ulani-vectors.json except crc (ChecksumTests) and the
/// image parts (FrameTests).
@Suite struct VectorTests {
    let v: JSON

    init() throws { v = try Vectors.root() }

    @Test func fileIsVersionOne() {
        #expect(v["version"]?.int == 1)
    }

    @Test func panel() throws {
        let p = try #require(v["panel"])
        #expect(p["width"]?.int == Panel.width)
        #expect(p["height"]?.int == Panel.height)
        #expect(p["pixels_per_byte"]?.int == Panel.pixelsPerByte)
        #expect(p["frame_bytes"]?.int == Panel.frameBytes)
        #expect(p["user_slots"]?.array?.compactMap(\.int) == Array(Panel.userSlots))
        #expect(p["max_chunk"]?.int == Panel.maxChunk)
    }

    @Test func gattUUIDs() throws {
        let g = try #require(v["gatt"]?.object)
        let ours = [
            "advertised_service": GattUUID.advertisedService,
            "service": GattUUID.service,
            "command": GattUUID.command,
            "image": GattUUID.image,
            "model_number": GattUUID.modelNumber,
            "firmware_revision": GattUUID.firmwareRevision,
        ]
        #expect(Set(g.keys) == Set(ours.keys))
        for (key, value) in g {
            let expected = try #require(value.string)
            #expect(ours[key]?.lowercased() == expected.lowercased(), "gatt.\(key)")
        }
    }

    @Test func imageHeaders() throws {
        let cases = try #require(v["image_header"]?.array)
        #expect(cases.count == 4)
        #expect(cases.contains { $0["mode"]?.int == 2 })
        for c in cases {
            let input = try Vectors.input(try #require(c["input"]))
            let slot = try #require(c["slot"]?.int)
            let mode = try #require(c["mode"]?.int)
            let header = try Messages.imageHeader(frameBytes: input, page: slot, mode: mode)
            #expect(header.count == 13)
            #expect(toHex(header) == c["header"]?.string, "slot \(slot) mode \(mode)")
        }
    }

    @Test func commands() throws {
        let c = try #require(v["commands"])
        #expect(toHex(Command.unlock) == c["unlock"]?.string)
        #expect(toHex(Command.battery) == c["battery"]?.string)
        #expect(toHex(Command.deviceInfo) == c["device_info"]?.string)
        #expect(toHex(Command.getSlot) == c["get_slot"]?.string)
        #expect(toHex(Command.disconnect) == c["disconnect"]?.string)
        let show = try #require(c["show_slot"]?.object)
        #expect(Set(show.keys) == ["1", "2", "3", "4"])
        for (key, hex) in show {
            let page = try #require(Int(key))
            #expect(toHex(try Messages.showSlot(page: page)) == hex.string, "show_slot \(key)")
        }
    }

    @Test func replyConstants() throws {
        let r = try #require(v["replies"])
        #expect(toHex(Reply.unlockOK) == r["unlock_ok"]?.string)
        #expect(toHex(Reply.headerOK) == r["header"]?["ok"]?.string)
        #expect(toHex(Reply.headerBusy) == r["header"]?["busy"]?.string)
        #expect(toHex(Reply.headerSameImage) == r["header"]?["same_image"]?.string)
        #expect(toHex(Reply.dataOK) == r["data"]?["ok"]?.string)
        #expect(toHex(Reply.dataFail) == r["data"]?["fail"]?.string)
        #expect(toHex(Reply.showSlotOK) == r["show_slot_ok"]?.string)
        #expect(toHex(Reply.deviceReady) == r["device_ready"]?.string)
    }

    @Test func batteryReplies() throws {
        let cases = try #require(v["replies"]?["battery"]?.array)
        #expect(cases.count == 4)
        for c in cases {
            let hex = try #require(c["reply"]?.string)
            let level = try #require(c["level"])  // present; null while charging
            let battery = try Messages.parseBattery(fromHex(hex))
            #expect(battery.level == level.int, "battery \(hex)")
            #expect(level.isNull == (battery.level == nil), "battery \(hex)")
            #expect(battery.charging == c["charging"]?.bool, "battery \(hex)")
        }
        #expect(try Messages.parseBattery(fromHex("0606")) == Battery(level: nil, charging: true))
    }

    @Test func slotReplies() throws {
        let cases = try #require(v["replies"]?["get_slot"]?.array)
        #expect(cases.count == 2)
        for c in cases {
            let hex = try #require(c["reply"]?.string)
            let crc = try #require(c["crc32"]?.string.flatMap { UInt32($0, radix: 16) })
            let slot = try Messages.parseSlot(fromHex(hex))
            #expect(slot.page == c["slot"]?.int, "get_slot \(hex)")
            #expect(slot.crc32 == crc, "get_slot \(hex)")
        }
    }

    @Test func deviceInfoReplies() throws {
        let cases = try #require(v["replies"]?["device_info"]?.array)
        #expect(!cases.isEmpty)
        for c in cases {
            let info = try Messages.parseDeviceInfo(fromHex(try #require(c["reply"]?.string)))
            #expect(info.mac == c["mac"]?.string)
            #expect(info.serial == c["serial"]?.string)
        }
    }

    @Test func pushOrder() throws {
        let cases = try #require(v["push_order"]?.array)
        #expect(cases.count == 4)
        for c in cases {
            let shown = try #require(c["shown"]?.int)
            let slots = try #require(c["slots"]?.array).compactMap(\.int)
            let order = try #require(c["order"]?.array).compactMap(\.int)
            #expect(PushPlan.order(pages: slots, shown: shown) == order, "shown \(shown) slots \(slots)")
        }
    }
}
