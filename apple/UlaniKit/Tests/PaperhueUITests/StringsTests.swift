import Foundation
import Testing
import UlaniKit
@testable import PaperhueUI

// Mirrors python/tests/test_gui_model.py and python/tests/test_gui.py (describe, friendly).

@Suite struct DescribeTests {
    @Test(arguments: [
        (PushEvent(page: 2, phase: .start, index: 0, count: 4, sent: 0, total: 1000), "準備傳送（1/4）", 0),
        (PushEvent(page: 2, phase: .sending, index: 0, count: 4, sent: 250, total: 1000), "傳送中 25%", 25),
        (PushEvent(page: 2, phase: .done, index: 0, count: 4, sent: 1000, total: 1000), "完成", 100),
        (PushEvent(page: 2, phase: .unchanged, index: 0, count: 4, sent: 1000, total: 1000), "已是這張照片，略過", 100),
        (PushEvent(page: 2, phase: .refreshing, index: 3, count: 4, sent: 1000, total: 1000), "完成（畫面約需 40 秒刷新）", 100),
    ])
    func describeTurnsPushEventsIntoTileText(event: PushEvent, text: String, percent: Int) {
        let described = Strings.describe(event)
        #expect(described.page == 2)
        #expect(described.text == text)
        #expect(described.percent == percent)
    }

    @Test func percentRoundsDownAndSurvivesAZeroTotal() {
        #expect(Strings.describe(PushEvent(page: 1, phase: .sending, index: 0, count: 1, sent: 1999, total: 2000)).percent == 99)
        let empty = Strings.describe(PushEvent(page: 1, phase: .sending, index: 0, count: 1, sent: 0, total: 0))
        #expect(empty.text == "傳送中 0%" && empty.percent == 0)
    }
}

@Suite struct FriendlyTests {
    static let bond = "裝置與這台電腦的配對已失效。請到藍牙設定忘記這個裝置，按住裝置按鍵約 5 秒（綠燈閃爍）後重新配對。"
    static let silent = "裝置沒有回應（可能正在刷新畫面）。請等一分鐘後再推送一次。"
    static let badData = "裝置回報收到的資料有誤，請再推送一次。"
    static let notFound = "找不到裝置或連不上。請確認：裝置在附近、藍牙已開啟、裝置已與這台電腦配對，且沒有其他手機或電腦正在連線。"
    static let bluetoothOff = "藍牙未開啟或未允許本 App 使用藍牙。請到設定開啟。"
    static let linkLost = "藍牙連線中斷。請靠近裝置後再推送一次。"

    @Test(arguments: [
        (UlaniError.bondLost, bond),
        (UlaniError.deviceBusy(what: "an image for page 2"), silent),
        (UlaniError.noReply(opcode: 0x0C), silent),
        (UlaniError.uploadFailed(page: 1, reply: Data([0x02, 0x01])), badData),
        (UlaniError.notFound, notFound),
        (UlaniError.connectFailed(attempts: 4, last: "no e-paper device found"), notFound),
        (UlaniError.bluetoothUnavailable("powered off"), bluetoothOff),
        (UlaniError.linkLost("disconnected"), linkLost),
    ])
    func eachKindOfErrorGetsItsHint(error: UlaniError, hint: String) {
        #expect(Strings.hint(for: error) == hint)
        // Like gui.friendly: the hint, a blank line, then the technical message.
        #expect(Strings.friendly(error) == "\(hint)\n\n\(error.description)")
    }

    @Test func pushErrorsAreExplainedByTheirCause() {
        let error = PushError(page: 2, completed: [1: .ok], underlying: .deviceBusy(what: "an image for page 2"))
        #expect(Strings.hint(for: error) == Self.silent)
        let text = Strings.friendly(error)
        #expect(text.hasPrefix(Self.silent))
        #expect(text.hasSuffix(error.description))
        #expect(text.contains("page 2:"))
    }

    @Test func errorsWithoutAHintShowOnlyTheTechnicalMessage() {
        let error = UlaniError.unexpectedHeaderReply(page: 3, reply: Data([0x01, 0x05]))
        #expect(Strings.hint(for: error) == nil)
        #expect(Strings.friendly(error) == error.description)
        let other: any Error = CocoaError(.fileReadCorruptFile)
        #expect(Strings.friendly(other) == String(describing: other))
    }
}

@Suite struct StatusTextTests {
    @Test func pushSummary() {
        #expect(Strings.pushDone(changed: 3, unchanged: 1) == "完成：3 頁已更新，1 頁原本就相同。")
    }

    @Test func quitWarningMatchesTheWindowsApp() {
        #expect(Strings.quitWhilePushingTitle == "仍在傳送")
        #expect(Strings.quitWhilePushingMessage == "照片還在傳送中，現在關閉會中斷傳送。確定要關閉嗎？")
    }

    @Test func deviceStatusShowsBatteryAndPage() {
        #expect(Strings.deviceStatus(CalendarStatus(battery: Battery(level: 4, charging: false), shown: 3))
                == "裝置狀態：電量 4/5，目前顯示第 3 頁")
        #expect(Strings.deviceStatus(CalendarStatus(battery: Battery(level: nil, charging: true), shown: 1))
                == "裝置狀態：電量 充電中，目前顯示第 1 頁")
    }

    @Test func crcLineIsZeroPaddedLowerCaseHex() throws {
        let frame = try Frame(bytes: Data(repeating: 0x11, count: Frame.byteCount))
        let expected = String(format: "第 2 頁 CRC32 %08x CRC16 %04x", frame.crc32, frame.crc16)
        #expect(Strings.crcLine(page: 2, frame: frame) == expected)
        #expect(Strings.crcLine(page: 2, frame: frame).count == "第 2 頁 CRC32 00000000 CRC16 0000".count)
    }

    @Test func verifySummaryNamesDifferingPages() {
        #expect(Strings.verifyDone(matching: [1, 2, 3, 4], differing: []) == "驗證完成：4 頁都與推送的照片相同。")
        #expect(Strings.verifyDone(matching: [1, 3], differing: [2, 4]) == "驗證完成：第 2、4 頁與推送的照片不同。")
    }

    @Test(arguments: [
        (UlaniError.protocolError("unsupported image"), "無法讀取 notes.txt：不支援的檔案格式"),
        (UlaniError.protocolError("notes.txt: unsupported image"), "無法讀取 notes.txt：不支援的檔案格式"),
        (UlaniError.protocolError("notes.txt: cannot read the file"), "無法讀取 notes.txt：檔案無法開啟或已損壞"),
        (UlaniError.protocolError("something else"), "無法讀取 notes.txt：無法處理這個檔案"),
    ])
    func previewErrorsAreShortAndNameOnlyTheFile(error: UlaniError, text: String) {
        #expect(Strings.previewError(name: "notes.txt", error: error) == text)
    }

    @Test func previewErrorOfAFileThatCannotBeOpened() {
        #expect(Strings.previewError(name: "a.jpg", error: CocoaError(.fileReadNoSuchFile))
                == "無法讀取 a.jpg：檔案無法開啟或已損壞")
        #expect(Strings.previewError(name: nil, error: UlaniError.protocolError("unsupported image"))
                == "無法讀取這張照片：不支援的檔案格式")
    }
}
