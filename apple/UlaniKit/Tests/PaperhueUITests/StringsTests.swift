import Foundation
import Testing
import UlaniKit
@testable import PaperhueUI

// Mirrors python/tests/test_gui_model.py and python/tests/test_gui.py (describe, friendly),
// in both interface languages.

private let zh = Strings(.chinese)
private let en = Strings(.english)

/// Whether `text` has a Chinese character (CJK ideograph).
func hasChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
}

/// Whether `text` has a Chinese character or CJK punctuation (「」、。, full-width ：，（）).
func hasCJK(_ text: String) -> Bool {
    hasChinese(text) || text.unicodeScalars.contains {
        (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
    }
}

@Suite struct KeyParityTests {
    /// Every fixed text exists in both languages: Chinese with Chinese characters, English
    /// without any CJK character or punctuation.
    @Test(arguments: Strings.Key.allCases)
    func everyKeyHasBothLanguages(key: Strings.Key) {
        let chinese = zh[key], english = en[key]
        #expect(!chinese.isEmpty && !english.isEmpty)
        #expect(hasChinese(chinese), "\(key): \(chinese)")
        #expect(!hasCJK(english), "\(key): \(english)")
        #expect(chinese != english)
    }

    @Test func englishNeverCallsTheDeviceACalendar() {
        // These speak of calendar data (iCal sources), which may say calendar (shared/LANGUAGE.md).
        let calendarData: Set<Strings.Key> = [
            .feedsNone, .feedsButton, .feedsTitle, .feedsIntro, .feedsEmpty, .feedNamePrompt, .summaryIdle,
            .summaryReading, .summarySyncing, .reading, .schedulePrompt, .scheduleNote, .hintFeedError,
        ]
        for key in Strings.Key.allCases where !calendarData.contains(key) {
            #expect(!en[key].lowercased().contains("calendar"), "\(key)")
        }
        for key in calendarData {
            #expect(!en[key].contains("the calendar device") && !en[key].contains("to the calendar"), "\(key)")
        }
    }

    @Test func formattedTextsAreInTheirLanguage() throws {
        let status = CalendarStatus(battery: Battery(level: nil, charging: true), shown: 2)
        let texts: (Strings) -> [String] = { strings in
            [strings.pageTitle(3), strings.choosePhotoLabel(page: 3), strings.pageProgress(3),
             strings.pushDone(changed: 2, unchanged: 1), strings.deviceStatus(status),
             strings.previewError(name: nil, reason: .other),
             strings.cropTitle(page: 2), strings.cropZoomValue(2.5)]
                + Grain.allCases.map(strings.grain)
                + CropGeometry.Direction.allCases.map(strings.cropMove)
                + [PushEvent.Phase.start, .sending, .unchanged, .refreshing, .switching, .done].map {
                    strings.describe(PushEvent(page: 1, phase: $0, index: 0, count: 2, sent: 1, total: 2)).text
                }
        }
        for (chinese, english) in zip(texts(zh), texts(en)) {
            #expect(hasChinese(chinese), "\(chinese)")
            #expect(!hasCJK(english), "\(english)")
        }
    }
}

@Suite struct DescribeTests {
    @Test(arguments: [
        (PushEvent(page: 2, phase: .start, index: 0, count: 4, sent: 0, total: 1000), "準備傳送（1/4）", 0),
        (PushEvent(page: 2, phase: .sending, index: 0, count: 4, sent: 250, total: 1000), "傳送中 25%", 25),
        (PushEvent(page: 2, phase: .done, index: 0, count: 4, sent: 1000, total: 1000), "完成", 100),
        (PushEvent(page: 2, phase: .unchanged, index: 0, count: 4, sent: 1000, total: 1000), "已是這張照片，略過", 100),
        (PushEvent(page: 2, phase: .refreshing, index: 3, count: 4, sent: 1000, total: 1000), "完成（畫面約需 40 秒刷新）", 100),
        (PushEvent(page: 2, phase: .switching, index: 3, count: 4), "切換顯示這一頁（畫面約需 40 秒刷新）", 100),
    ])
    func describeTurnsPushEventsIntoTileText(event: PushEvent, text: String, percent: Int) {
        let described = zh.describe(event)
        #expect(described.page == 2)
        #expect(described.text == text)
        #expect(described.percent == percent)
    }

    @Test(arguments: [
        (PushEvent(page: 2, phase: .start, index: 0, count: 4, sent: 0, total: 1000), "Getting ready (1/4)"),
        (PushEvent(page: 2, phase: .sending, index: 0, count: 4, sent: 250, total: 1000), "Sending 25%"),
        (PushEvent(page: 2, phase: .done, index: 0, count: 4, sent: 1000, total: 1000), "Done"),
        (PushEvent(page: 2, phase: .unchanged, index: 0, count: 4, sent: 1000, total: 1000), "Already has this photo, skipped"),
        (PushEvent(page: 2, phase: .refreshing, index: 3, count: 4, sent: 1000, total: 1000),
         "Done (the screen takes about 40 s to refresh)"),
        (PushEvent(page: 2, phase: .switching, index: 3, count: 4),
         "Switching to this page (the screen takes about 40 s to refresh)"),
    ])
    func describeInEnglish(event: PushEvent, text: String) {
        let described = en.describe(event)
        #expect(described.text == text)
        #expect(described.percent == zh.describe(event).percent)
    }

    @Test func percentRoundsDownAndSurvivesAZeroTotal() {
        #expect(zh.describe(PushEvent(page: 1, phase: .sending, index: 0, count: 1, sent: 1999, total: 2000)).percent == 99)
        let empty = zh.describe(PushEvent(page: 1, phase: .sending, index: 0, count: 1, sent: 0, total: 0))
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

    static let englishBond = "This computer is no longer paired with the device. Forget the device in Bluetooth settings, "
        + "then hold the device’s button for about 5 s (until the light blinks green) and pair again."
    static let englishSilent = "The device didn’t respond (it may be refreshing its screen). Wait a minute, then push again."
    static let englishBadData = "The device says the data it received was damaged. Push again."
    static let englishNotFound = "Can’t find or connect to the device. Check that it is nearby, Bluetooth is on, "
        + "the device is paired with this computer, and no other phone or computer is connected to it."
    static let englishBluetoothOff = "Bluetooth is off, or this app isn’t allowed to use it. Turn it on in System Settings."
    static let englishLinkLost = "The Bluetooth connection dropped. Move closer to the device and push again."

    @Test(arguments: [
        (UlaniError.bondLost, bond, englishBond),
        (UlaniError.deviceBusy(what: "an image for page 2"), silent, englishSilent),
        (UlaniError.noReply(opcode: 0x0C), silent, englishSilent),
        (UlaniError.uploadFailed(page: 1, reply: Data([0x02, 0x01])), badData, englishBadData),
        (UlaniError.notFound, notFound, englishNotFound),
        (UlaniError.connectFailed(attempts: 4, last: "no e-paper device found"), notFound, englishNotFound),
        (UlaniError.bluetoothUnavailable("powered off"), bluetoothOff, englishBluetoothOff),
        (UlaniError.linkLost("disconnected"), linkLost, englishLinkLost),
    ])
    func eachKindOfErrorGetsItsHint(error: UlaniError, hint: String, englishHint: String) {
        #expect(zh.hint(for: error) == hint)
        #expect(en.hint(for: error) == englishHint)
        // Like gui.friendly: the hint, a blank line, then the technical message.
        #expect(zh.friendly(error) == "\(hint)\n\n\(error.description)")
        #expect(en.friendly(error) == "\(englishHint)\n\n\(error.description)")
    }

    @Test func pushErrorsAreExplainedByTheirCause() {
        let error = PushError(page: 2, completed: [1: .ok], underlying: .deviceBusy(what: "an image for page 2"))
        #expect(zh.hint(for: error) == Self.silent)
        #expect(en.hint(for: error) == Self.englishSilent)
        for strings in [zh, en] {
            let text = strings.friendly(error)
            #expect(text.hasPrefix(strings.hint(for: error)!))
            #expect(text.hasSuffix(error.description))
            #expect(text.contains("page 2:"))
        }
    }

    @Test func errorsWithoutAHintShowOnlyTheTechnicalMessage() {
        let error = UlaniError.unexpectedHeaderReply(page: 3, reply: Data([0x01, 0x05]))
        let other: any Error = CocoaError(.fileReadCorruptFile)
        for strings in [zh, en] {
            #expect(strings.hint(for: error) == nil)
            #expect(strings.friendly(error) == error.description)
            #expect(strings.friendly(other) == String(describing: other))
        }
    }
}

@Suite struct GrainTests {
    /// The 顆粒感 picker: its segments in order, and the strength each one encodes with.
    @Test func levelsLabelsAndStrengths() {
        #expect(Grain.allCases == [.standard, .soft, .softer, .smoothest])
        #expect(Grain.allCases.map(zh.grain) == ["標準", "柔和", "更柔和", "最平滑"])
        #expect(Grain.allCases.map(en.grain) == ["Standard", "Soft", "Softer", "Smoothest"])
        #expect(Grain.allCases.map(\.strength) == [1.0, 0.8, 0.65, 0.5])
        #expect(zh[.grainLabel] == "顆粒感" && en[.grainLabel] == "Grain")
    }
}

@Suite struct StatusTextTests {
    @Test func pushSummary() {
        #expect(zh.pushDone(changed: 3, unchanged: 1) == "完成：3 頁已更新，1 頁原本就相同。")
        #expect(en.pushDone(changed: 3, unchanged: 1) == "Done: 3 pages updated, 1 page already the same.")
        #expect(en.pushDone(changed: 1, unchanged: 0) == "Done: 1 page updated, 0 pages already the same.")
        #expect(en.pushDone(changed: 0, unchanged: 2) == "Done: 0 pages updated, 2 pages already the same.")
    }

    @Test func quitWarningMatchesTheWindowsApp() {
        #expect(zh[.quitWhilePushingTitle] == "仍在傳送")
        #expect(zh[.quitWhilePushingMessage] == "照片還在傳送中，現在關閉會中斷傳送。確定要關閉嗎？")
        #expect(zh[.keepSending] == "繼續傳送" && zh[.quitAnyway] == "仍要關閉")
        #expect(en[.quitWhilePushingTitle] == "Still sending")
        #expect(en[.quitWhilePushingMessage] == "Photos are still being sent. Quitting now interrupts the transfer. Quit anyway?")
        #expect(en[.keepSending] == "Keep sending" && en[.quitAnyway] == "Quit anyway")
    }

    @Test func deviceStatusShowsBatteryAndPage() {
        let full = CalendarStatus(battery: Battery(level: 4, charging: false), shown: 3)
        let charging = CalendarStatus(battery: Battery(level: nil, charging: true), shown: 1)
        #expect(zh.deviceStatus(full) == "裝置狀態：電量 4/5，目前顯示第 3 頁")
        #expect(zh.deviceStatus(charging) == "裝置狀態：電量 充電中，目前顯示第 1 頁")
        #expect(en.deviceStatus(full) == "Device status: battery 4/5, showing page 3")
        #expect(en.deviceStatus(charging) == "Device status: battery charging, showing page 1")
    }

    @Test func cropEditorTexts() {
        #expect(zh[.adjustCrop] == "調整範圍…" && en[.adjustCrop] == "Adjust crop…")
        #expect(zh[.cropReset] == "重設" && en[.cropReset] == "Reset")
        #expect(zh[.cancel] == "取消" && en[.cancel] == "Cancel")
        #expect(zh[.confirm] == "確定" && en[.confirm] == "OK")
        #expect(zh.cropTitle(page: 3) == "調整第 3 頁的範圍" && en.cropTitle(page: 3) == "Adjust the crop of page 3")
        #expect(zh.cropZoomValue(1) == "放大 1.0 倍" && en.cropZoomValue(1) == "Zoomed 1.0x")
        #expect(zh.cropZoomValue(7.2) == "放大 7.2 倍" && en.cropZoomValue(2.449) == "Zoomed 2.4x")
        #expect(CropGeometry.Direction.allCases.map(zh.cropMove) == ["向左移", "向右移", "向上移", "向下移"])
        #expect(CropGeometry.Direction.allCases.map(en.cropMove) == ["Move left", "Move right", "Move up", "Move down"])
    }

    @Test func accessibilityLabelsOfATile() {
        #expect(zh.choosePhotoLabel(page: 1) == "第 1 頁 選擇照片…")
        #expect(en.choosePhotoLabel(page: 1) == "Choose a photo for page 1")
        #expect(zh.pageProgress(1) == "第 1 頁進度")
        #expect(en.pageProgress(1) == "Page 1 progress")
    }

    @Test(arguments: [
        (UlaniError.protocolError("unsupported image"), "無法讀取 notes.txt：不支援的檔案格式",
         "Can’t read notes.txt: unsupported file format"),
        (UlaniError.protocolError("notes.txt: unsupported image"), "無法讀取 notes.txt：不支援的檔案格式",
         "Can’t read notes.txt: unsupported file format"),
        (UlaniError.protocolError("notes.txt: cannot read the file"), "無法讀取 notes.txt：檔案無法開啟或已損壞",
         "Can’t read notes.txt: the file can’t be opened or is damaged"),
        (UlaniError.protocolError("something else"), "無法讀取 notes.txt：無法處理這個檔案",
         "Can’t read notes.txt: can’t process this file"),
    ])
    func previewErrorsAreShortAndNameOnlyTheFile(error: UlaniError, text: String, english: String) {
        #expect(zh.previewError(name: "notes.txt", error: error) == text)
        #expect(en.previewError(name: "notes.txt", error: error) == english)
    }

    @Test func aPhotoOver50MegapixelsSaysSoInFull() {
        let error = PhotoTooLarge(pixels: 50_320_896)
        #expect(PreviewFailure(error) == .tooLarge)
        #expect(zh.previewError(name: "IMG_1.jpg", error: error) == "照片超過 5000 萬像素的上限，請先縮小再選。")
        #expect(en.previewError(name: "IMG_1.jpg", error: error)
                == "This photo is over the 50-megapixel limit. Shrink it, then choose it again.")
    }

    @Test func previewErrorOfAFileThatCannotBeOpened() {
        #expect(zh.previewError(name: "a.jpg", error: CocoaError(.fileReadNoSuchFile))
                == "無法讀取 a.jpg：檔案無法開啟或已損壞")
        #expect(zh.previewError(name: nil, error: UlaniError.protocolError("unsupported image"))
                == "無法讀取這張照片：不支援的檔案格式")
        #expect(en.previewError(name: nil, error: UlaniError.protocolError("unsupported image"))
                == "Can’t read this photo: unsupported file format")
    }
}
