import Foundation
import UlaniKit

/// Every text the app shows, in Traditional Chinese (Taiwan, where the device is sold) or
/// English. The Chinese mirrors the Windows app (gui.py, gui_model.py). The view model keeps
/// state, not text, so switching the language changes every text on screen at once.
public struct Strings: Sendable {
    public let language: Language

    public init(_ language: Language) {
        self.language = language
    }

    /// The fixed texts. `subscript` gives each one in both languages, so a key without an
    /// English (or Chinese) text does not compile.
    public enum Key: String, CaseIterable, Sendable {
        case appTitle
        // Status row
        case deviceUnknown, deviceConnecting, deviceUnreachable, deviceJustPushed, readInfo, batteryCharging
        // Options
        case fitLabel, fitCover, fitContain
        case grainLabel, grainStandard, grainSoft, grainSofter, grainSmoothest
        // Tiles
        case choosePhoto, chooseFile, clear, noPhoto, unreadable, rendering, previewReady
        case waiting, unfinished, verifying, verifySame, verifyDifferent, notVerified
        case progressUnchanged, progressRefreshing, progressSwitching, progressDone
        case previewUnsupported, previewDamaged, previewUnprocessable, photoTooLarge
        // Crop (shared/CROP.md, Editor)
        case adjustCrop, adjustCropHelp, previewHelp
        case cropFrame, cropHint, cropZoom, cropNoZoom, cropReset, cropResetHelp, cancel, confirm
        case cropMoveLeft, cropMoveRight, cropMoveUp, cropMoveDown
        // Bottom bar
        case push, verify
        case summaryIdle, summaryPushing, summaryFailed, summaryVerifying, summaryVerifyFailed
        case technicalInfo, technicalInfoEmpty
        // Alerts
        case pushFailedTitle, infoFailedTitle, verifyFailedTitle, ok
        case hintBondLost, hintNoResponse, hintBadData, hintNotFound, hintBluetoothOff, hintLinkLost
        /// macOS: quitting during a push (gui.App.close).
        case quitWhilePushingTitle, quitWhilePushingMessage, keepSending, quitAnyway
        // Toolbar
        case languageToggleHint
        /// After a toggle: the menu bar keeps the launch language until the next launch.
        case menusNextLaunch
    }

    public subscript(_ key: Key) -> String {
        switch key {
        case .appTitle: pick("紙彩", "Paperhue")

        case .deviceUnknown: pick("裝置狀態：尚未讀取", "Device status: not read yet")
        case .deviceConnecting: pick("裝置狀態：連線中…", "Device status: connecting…")
        case .deviceUnreachable: pick("裝置狀態：連不上", "Device status: unreachable")
        case .deviceJustPushed:
            pick("裝置狀態：剛完成推送（按「讀取狀態」可更新）",
                 "Device status: just pushed (press “Read status” to update)")
        case .readInfo: pick("讀取狀態", "Read status")
        case .batteryCharging: pick("充電中", "charging")

        case .fitLabel: pick("顯示方式", "Fit")
        case .fitCover: pick("填滿畫面（裁切多餘部分）", "Fill the screen (crop the rest)")
        case .fitContain: pick("完整顯示（留白邊）", "Show all (white margins)")
        case .grainLabel: pick("顆粒感", "Grain")
        case .grainStandard: pick("標準", "Standard")
        case .grainSoft: pick("柔和", "Soft")
        case .grainSofter: pick("更柔和", "Softer")
        case .grainSmoothest: pick("最平滑", "Smoothest")

        case .choosePhoto: pick("選擇照片…", "Choose photo…")
        case .chooseFile: pick("從檔案…", "From file…")
        case .clear: pick("清除", "Clear")
        case .noPhoto: pick("尚未選擇照片", "No photo chosen")
        case .unreadable: pick("無法讀取這個檔案", "Can’t read this file")
        case .rendering: pick("產生預覽中…", "Making preview…")
        case .previewReady: pick("預覽為裝置實際顯示的 7 色效果", "Preview in the device’s 7 colours")
        case .waiting: pick("等待中", "Waiting")
        case .unfinished: pick("未完成", "Not finished")
        case .verifying: pick("驗證中…", "Verifying…")
        case .verifySame: pick("驗證：相同", "Verified: matches")
        case .verifyDifferent: pick("驗證：不同", "Verified: differs")
        case .notVerified: pick("未驗證", "Not verified")
        case .progressUnchanged: pick("已是這張照片，略過", "Already has this photo, skipped")
        case .progressRefreshing: pick("完成（畫面約需 40 秒刷新）", "Done (the screen takes about 40 s to refresh)")
        case .progressSwitching:
            pick("切換顯示這一頁（畫面約需 40 秒刷新）", "Switching to this page (the screen takes about 40 s to refresh)")
        case .progressDone: pick("完成", "Done")
        case .previewUnsupported: pick("不支援的檔案格式", "unsupported file format")
        case .previewDamaged: pick("檔案無法開啟或已損壞", "the file can’t be opened or is damaged")
        case .previewUnprocessable: pick("無法處理這個檔案", "can’t process this file")
        case .photoTooLarge: pick("照片超過 5000 萬像素的上限，請先縮小再選。",
                                  "This photo is over the 50-megapixel limit. Shrink it, then choose it again.")

        case .adjustCrop: pick("調整範圍…", "Adjust crop…")
        case .adjustCropHelp:
            pick("選擇照片的哪一部分填滿畫面（只用於「填滿畫面」）",
                 "Choose the part of the photo that fills the screen (with “Fill the screen” only)")
        case .previewHelp: pick("按一下選擇照片，按兩下調整範圍", "Click to choose a photo, double-click to adjust the crop")
        case .cropFrame: pick("裁切範圍", "Crop frame")
        case .cropHint:
            pick("拖曳框內可移動範圍，拖曳四個角可調整大小；也可以用觸控板捏合、滑鼠滾輪或下方的滑桿縮放。"
                 + "方向鍵每次移動 1%，按住 Shift 為 10%。",
                 "Drag inside the frame to move it, or a corner to resize it; pinching, the scroll wheel and "
                 + "the slider below zoom too. The arrow keys move it 1% at a time, 10% with Shift.")
        case .cropZoom: pick("縮放", "Zoom")
        case .cropNoZoom: pick("這張照片太小，無法再放大。", "This photo is too small to zoom in.")
        case .cropReset: pick("重設", "Reset")
        case .cropResetHelp: pick("回到預設：照片中央、不放大", "Back to the default: the middle of the photo, not zoomed")
        case .cancel: pick("取消", "Cancel")
        case .confirm: pick("確定", "OK")
        case .cropMoveLeft: pick("向左移", "Move left")
        case .cropMoveRight: pick("向右移", "Move right")
        case .cropMoveUp: pick("向上移", "Move up")
        case .cropMoveDown: pick("向下移", "Move down")

        case .push: pick("推送到裝置", "Push to device")
        case .verify: pick("驗證", "Verify")
        case .summaryIdle:
            pick("選擇 1–4 張照片後按「推送到裝置」。正在顯示的那一頁會最後傳，全部約需 2 分鐘。",
                 "Choose 1–4 photos, then press “Push to device”. The page on screen goes last; "
                 + "it all takes about 2 minutes.")
        case .summaryPushing:
            pick("連線並推送中…（正在顯示的那一頁會最後傳）", "Connecting and pushing… (the page on screen goes last)")
        case .summaryFailed: pick("推送失敗，請看錯誤訊息後再試一次。", "Push failed. Read the error message, then try again.")
        case .summaryVerifying:
            pick("驗證中…（只比對每頁的照片，裝置畫面不會改變）",
                 "Verifying… (only each page’s photo is compared; the screen doesn’t change)")
        case .summaryVerifyFailed:
            pick("驗證失敗，請看錯誤訊息後再試一次。", "Verification failed. Read the error message, then try again.")
        case .technicalInfo: pick("技術資訊", "Technical details")
        case .technicalInfoEmpty:
            pick("推送後這裡會列出每頁的 CRC32 / CRC16。", "After a push, each page’s CRC32 / CRC16 is listed here.")

        case .pushFailedTitle: pick("推送失敗", "Push failed")
        case .infoFailedTitle: pick("讀取狀態失敗", "Couldn’t read the status")
        case .verifyFailedTitle: pick("驗證失敗", "Verification failed")
        case .ok: pick("好", "OK")
        case .hintBondLost:
            pick("裝置與這台電腦的配對已失效。請到藍牙設定忘記這個裝置，按住裝置按鍵約 5 秒（綠燈閃爍）後重新配對。",
                 "This computer is no longer paired with the device. Forget the device in Bluetooth settings, "
                 + "then hold the device’s button for about 5 s (until the light blinks green) and pair again.")
        case .hintNoResponse:
            pick("裝置沒有回應（可能正在刷新畫面）。請等一分鐘後再推送一次。",
                 "The device didn’t respond (it may be refreshing its screen). Wait a minute, then push again.")
        case .hintBadData:
            pick("裝置回報收到的資料有誤，請再推送一次。", "The device says the data it received was damaged. Push again.")
        case .hintNotFound:
            pick("找不到裝置或連不上。請確認：裝置在附近、藍牙已開啟、裝置已與這台電腦配對，且沒有其他手機或電腦正在連線。",
                 "Can’t find or connect to the device. Check that it is nearby, Bluetooth is on, the device is paired "
                 + "with this computer, and no other phone or computer is connected to it.")
        case .hintBluetoothOff:
            pick("藍牙未開啟或未允許本 App 使用藍牙。請到設定開啟。",
                 "Bluetooth is off, or this app isn’t allowed to use it. Turn it on in System Settings.")
        case .hintLinkLost:
            pick("藍牙連線中斷。請靠近裝置後再推送一次。", "The Bluetooth connection dropped. Move closer to the device and push again.")
        case .quitWhilePushingTitle: pick("仍在傳送", "Still sending")
        case .quitWhilePushingMessage:
            pick("照片還在傳送中，現在關閉會中斷傳送。確定要關閉嗎？",
                 "Photos are still being sent. Quitting now interrupts the transfer. Quit anyway?")
        case .keepSending: pick("繼續傳送", "Keep sending")
        case .quitAnyway: pick("仍要關閉", "Quit anyway")

        case .languageToggleHint: pick("切換介面語言", "Switch the interface language")
        case .menusNextLaunch:
            pick("選單列和系統對話框會在下次開啟紙彩時換成中文。",
                 "The menu bar and system dialogs switch to English the next time you open Paperhue.")
        }
    }

    private func pick(_ chinese: String, _ english: String) -> String {
        switch language {
        case .chinese: chinese
        case .english: english
        }
    }

    // MARK: formatted texts

    public func pageTitle(_ page: Int) -> String { pick("第 \(page) 頁", "Page \(page)") }

    /// Accessibility label of a tile's preview, which opens the photo picker.
    public func choosePhotoLabel(page: Int) -> String {
        pick("\(pageTitle(page)) \(self[.choosePhoto])", "Choose a photo for page \(page)")
    }

    /// Accessibility label of a tile's progress bar.
    public func pageProgress(_ page: Int) -> String { pick("第 \(page) 頁進度", "Page \(page) progress") }

    /// The crop editor's title.
    public func cropTitle(page: Int) -> String { pick("調整第 \(page) 頁的範圍", "Adjust the crop of page \(page)") }

    /// The crop editor's zoom (`CropGeometry.zoom`), one decimal: 放大 2.5 倍.
    public func cropZoomValue(_ zoom: Double) -> String {
        let value = String(format: "%.1f", zoom)
        return pick("放大 \(value) 倍", "Zoomed \(value)x")
    }

    /// An arrow key's accessibility action in the crop editor.
    public func cropMove(_ direction: CropGeometry.Direction) -> String {
        switch direction {
        case .left: self[.cropMoveLeft]
        case .right: self[.cropMoveRight]
        case .up: self[.cropMoveUp]
        case .down: self[.cropMoveDown]
        }
    }

    public func grain(_ grain: Grain) -> String {
        switch grain {
        case .standard: self[.grainStandard]
        case .soft: self[.grainSoft]
        case .softer: self[.grainSofter]
        case .smoothest: self[.grainSmoothest]
        }
    }

    public func pushDone(changed: Int, unchanged: Int) -> String {
        pick("完成：\(changed) 頁已更新，\(unchanged) 頁原本就相同。",
             "Done: \(pages(changed)) updated, \(pages(unchanged)) already the same.")
    }

    public func verifyDone(matching: [Int], differing: [Int]) -> String {
        if differing.isEmpty {
            let count = matching.count
            return pick("驗證完成：\(count) 頁都與推送的照片相同。",
                        count == 1 ? "Verified: 1 page matches the pushed photo."
                                   : "Verified: all \(count) pages match the pushed photos.")
        }
        let sorted = differing.sorted().map(String.init)
        switch language {
        case .chinese:
            return "驗證完成：第 \(sorted.joined(separator: "、")) 頁與推送的照片不同。"
        case .english:
            if sorted.count == 1 {
                return "Verified: page \(sorted[0]) differs from the pushed photo."
            }
            let list = sorted.dropLast().joined(separator: ", ") + " and " + sorted[sorted.count - 1]
            return "Verified: pages \(list) differ from the pushed photos."
        }
    }

    public func verifyLine(page: Int, result: CalendarSession.ProbeResult) -> String {
        "\(pageTitle(page)) \(self[result == .matches ? .verifySame : .verifyDifferent])"
    }

    public func deviceStatus(_ status: CalendarStatus) -> String {
        let battery = status.battery
        let level = battery.charging ? self[.batteryCharging] : "\(battery.level.map(String.init) ?? "?")/5"
        return pick("裝置狀態：電量 \(level)，目前顯示第 \(status.shown) 頁",
                    "Device status: battery \(level), showing page \(status.shown)")
    }

    /// `第 N 頁 CRC32 xxxxxxxx CRC16 xxxx`, for comparing with `ulani-swift probe` / the PC.
    public func crcLine(page: Int, frame: Frame) -> String {
        crcLine(page: page, crc32: frame.crc32, crc16: frame.crc16)
    }

    public func crcLine(page: Int, crc32: UInt32, crc16: UInt16) -> String {
        "\(pageTitle(page)) CRC32 \(Self.hex(crc32, digits: 8)) CRC16 \(Self.hex(UInt32(crc16), digits: 4))"
    }

    /// One line of the technical log about a failed job: its alert title, then the error.
    public func failureLine(_ job: PushViewModel.Job, detail: String) -> String {
        pick("\(failureTitle(job))：\(detail)", "\(failureTitle(job)): \(detail)")
    }

    /// A tile's text for one step of its push (gui_model.describe).
    public func progress(_ progress: PushProgress) -> String {
        switch progress.phase {
        case .start: pick("準備傳送（\(progress.index + 1)/\(progress.count)）",
                          "Getting ready (\(progress.index + 1)/\(progress.count))")
        case .sending: pick("傳送中 \(progress.percent)%", "Sending \(progress.percent)%")
        case .unchanged: self[.progressUnchanged]
        case .refreshing: self[.progressRefreshing]
        case .switching: self[.progressSwitching]
        case .done: self[.progressDone]
        }
    }

    /// (page, status text, percent) for one push progress event (gui_model.describe).
    public func describe(_ event: PushEvent) -> (page: Int, text: String, percent: Int) {
        let progress = PushProgress(event)
        return (event.page, self.progress(progress), progress.percent)
    }

    /// What the user can do about `error`, or nil when there is nothing to suggest.
    public func hint(for error: any Error) -> String? {
        ErrorHint(error).map(hint)
    }

    public func hint(_ hint: ErrorHint) -> String {
        switch hint {
        case .bondLost: self[.hintBondLost]
        case .noResponse: self[.hintNoResponse]
        case .badData: self[.hintBadData]
        case .notFound: self[.hintNotFound]
        case .bluetoothOff: self[.hintBluetoothOff]
        case .linkLost: self[.hintLinkLost]
        }
    }

    /// A short explanation in the interface language, followed by the technical message
    /// (gui.friendly).
    public func friendly(_ error: any Error) -> String {
        friendly(hint: ErrorHint(error), detail: String(describing: error))
    }

    /// The hint, a blank line, then the technical message; only the message without a hint.
    public func friendly(hint: ErrorHint?, detail: String) -> String {
        guard let hint else { return detail }
        return "\(self.hint(hint))\n\n\(detail)"
    }

    /// Why a photo could not be turned into a preview; names only the file, never its folder.
    public func previewError(name: String?, error: any Error) -> String {
        previewError(name: name, reason: PreviewFailure(error))
    }

    public func previewError(name: String?, reason: PreviewFailure) -> String {
        let why: String
        switch reason {
        case .unsupportedFormat: why = self[.previewUnsupported]
        case .unreadable: why = self[.previewDamaged]
        case .other: why = self[.previewUnprocessable]
        case .tooLarge: return self[.photoTooLarge]  // the whole text, the same in every app
        }
        return switch language {
        case .chinese: "\(name.map { "無法讀取 \($0)" } ?? "無法讀取這張照片")：\(why)"
        case .english: "\(name.map { "Can’t read \($0)" } ?? "Can’t read this photo"): \(why)"
        }
    }

    // MARK: view model state

    public func summary(_ summary: PushViewModel.Summary) -> String {
        switch summary {
        case .idle: self[.summaryIdle]
        case .pushing: self[.summaryPushing]
        case .pushDone(let changed, let unchanged): pushDone(changed: changed, unchanged: unchanged)
        case .pushFailed: self[.summaryFailed]
        case .verifying: self[.summaryVerifying]
        case .verifyDone(let matching, let differing): verifyDone(matching: matching, differing: differing)
        case .verifyFailed: self[.summaryVerifyFailed]
        }
    }

    public func deviceStatus(_ status: PushViewModel.DeviceStatus) -> String {
        switch status {
        case .unknown: self[.deviceUnknown]
        case .connecting: self[.deviceConnecting]
        case .unreachable: self[.deviceUnreachable]
        case .justPushed: self[.deviceJustPushed]
        case .status(let status): deviceStatus(status)
        }
    }

    /// A tile's text under its progress bar.
    public func pageStatus(_ status: PageStatus) -> String {
        switch status {
        case .blank: ""
        case .rendering: self[.rendering]
        case .previewReady: self[.previewReady]
        case .previewFailed(let name, let reason): previewError(name: name, reason: reason)
        case .waiting: self[.waiting]
        case .progress(let progress): self.progress(progress)
        case .unfinished: self[.unfinished]
        case .verifying: self[.verifying]
        case .verified(let result): self[result == .matches ? .verifySame : .verifyDifferent]
        case .notVerified: self[.notVerified]
        }
    }

    public func logLine(_ entry: PushViewModel.LogEntry) -> String {
        switch entry {
        case .crc(let page, let crc32, let crc16): crcLine(page: page, crc32: crc32, crc16: crc16)
        case .failed(let job, let detail): failureLine(job, detail: detail)
        case .verified(let page, let result): verifyLine(page: page, result: result)
        }
    }

    public func alertTitle(_ alert: PushViewModel.Alert) -> String { failureTitle(alert.job) }

    public func alertMessage(_ alert: PushViewModel.Alert) -> String {
        friendly(hint: alert.hint, detail: alert.detail)
    }

    private func failureTitle(_ job: PushViewModel.Job) -> String {
        switch job {
        case .push: self[.pushFailedTitle]
        case .info: self[.infoFailedTitle]
        case .verify: self[.verifyFailedTitle]
        }
    }

    /// "1 page", "2 pages".
    private func pages(_ count: Int) -> String { count == 1 ? "1 page" : "\(count) pages" }

    private static func hex(_ value: UInt32, digits: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}

/// What the user can do about an error; `Strings.hint` gives the text. Errors without a
/// hint show only their technical message.
public enum ErrorHint: Sendable, Equatable {
    case bondLost, noResponse, badData, notFound, bluetoothOff, linkLost

    /// nil when there is nothing to suggest.
    public init?(_ error: any Error) {
        switch UlaniError.from(error) {
        case .bondLost: self = .bondLost
        case .deviceBusy, .noReply: self = .noResponse
        case .uploadFailed: self = .badData
        case .notFound, .connectFailed: self = .notFound
        case .bluetoothUnavailable: self = .bluetoothOff
        case .linkLost: self = .linkLost
        case .unlockRejected, .unexpectedHeaderReply, .protocolError, nil: return nil
        }
    }
}

/// Why a photo could not be turned into a preview (`Strings.previewError`).
public enum PreviewFailure: Sendable, Equatable {
    case unsupportedFormat
    /// The file cannot be opened or is damaged.
    case unreadable
    case other
    /// Over 50 megapixels (`PhotoTooLarge`): refused, the user shrinks it first.
    case tooLarge

    public init(_ error: any Error) {
        let message = String(describing: error)
        if error is PhotoTooLarge {
            self = .tooLarge
        } else if message.contains("unsupported image") {
            self = .unsupportedFormat
        } else if message.contains("cannot read") || Self.isFileError(error) {
            self = .unreadable
        } else {
            self = .other
        }
    }

    private static func isFileError(_ error: any Error) -> Bool {
        let domain = (error as NSError).domain
        return domain == NSCocoaErrorDomain || domain == NSPOSIXErrorDomain
    }
}
