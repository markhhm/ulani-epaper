import Foundation
import UlaniKit

/// Every text the app shows. Traditional Chinese (Taiwan) on purpose: the device is sold
/// in Taiwan. Mirrors the Windows app (gui.py, gui_model.py).
public enum Strings {
    public static let appTitle = "紙彩"

    // Status row
    public static let deviceUnknown = "裝置狀態：尚未讀取"
    public static let deviceConnecting = "裝置狀態：連線中…"
    public static let deviceUnreachable = "裝置狀態：連不上"
    public static let deviceJustPushed = "裝置狀態：剛完成推送（按「讀取狀態」可更新）"
    public static let readInfo = "讀取狀態"

    // Options
    public static let fitLabel = "顯示方式"
    public static let fitCover = "填滿畫面（裁切多餘部分）"
    public static let fitContain = "完整顯示（留白邊）"
    public static let grainLabel = "顆粒感"
    public static let grainStandard = "標準"
    public static let grainSoft = "柔和"
    public static let grainSofter = "更柔和"
    public static let grainSmoothest = "最平滑"

    // Tiles
    public static let choosePhoto = "選擇照片…"
    public static let chooseFile = "從檔案…"
    public static let clear = "清除"
    public static let noPhoto = "尚未選擇照片"
    public static let unreadable = "無法讀取這個檔案"
    public static let rendering = "產生預覽中…"
    public static let previewReady = "預覽為裝置實際顯示的 7 色效果"
    public static let waiting = "等待中"
    public static let unfinished = "未完成"
    public static let verifying = "驗證中…"
    public static let verifySame = "驗證：相同"
    public static let verifyDifferent = "驗證：不同"
    public static let notVerified = "未驗證"

    // Bottom bar
    public static let push = "推送到裝置"
    public static let verify = "驗證"
    public static let summaryIdle = "選擇 1–4 張照片後按「推送到裝置」。正在顯示的那一頁會最後傳，全部約需 2 分鐘。"
    public static let summaryPushing = "連線並推送中…（正在顯示的那一頁會最後傳）"
    public static let summaryFailed = "推送失敗，請看錯誤訊息後再試一次。"
    public static let summaryVerifying = "驗證中…（只比對每頁的照片，裝置畫面不會改變）"
    public static let summaryVerifyFailed = "驗證失敗，請看錯誤訊息後再試一次。"
    public static let technicalInfo = "技術資訊"
    public static let technicalInfoEmpty = "推送後這裡會列出每頁的 CRC32 / CRC16。"

    // Alerts
    public static let pushFailedTitle = "推送失敗"
    public static let infoFailedTitle = "讀取狀態失敗"
    public static let verifyFailedTitle = "驗證失敗"
    public static let ok = "好"
    /// macOS: quitting during a push (gui.App.close).
    public static let quitWhilePushingTitle = "仍在傳送"
    public static let quitWhilePushingMessage = "照片還在傳送中，現在關閉會中斷傳送。確定要關閉嗎？"
    public static let keepSending = "繼續傳送"
    public static let quitAnyway = "仍要關閉"

    public static func pageTitle(_ page: Int) -> String { "第 \(page) 頁" }

    public static func pushDone(changed: Int, unchanged: Int) -> String {
        "完成：\(changed) 頁已更新，\(unchanged) 頁原本就相同。"
    }

    public static func verifyDone(matching: [Int], differing: [Int]) -> String {
        if differing.isEmpty {
            return "驗證完成：\(matching.count) 頁都與推送的照片相同。"
        }
        let pages = differing.sorted().map(String.init).joined(separator: "、")
        return "驗證完成：第 \(pages) 頁與推送的照片不同。"
    }

    public static func verifyLine(page: Int, result: CalendarSession.ProbeResult) -> String {
        "\(pageTitle(page)) \(result == .matches ? verifySame : verifyDifferent)"
    }

    public static func deviceStatus(_ status: CalendarStatus) -> String {
        let battery = status.battery
        let level = battery.charging ? "充電中" : "\(battery.level.map(String.init) ?? "?")/5"
        return "裝置狀態：電量 \(level)，目前顯示第 \(status.shown) 頁"
    }

    /// `第 N 頁 CRC32 xxxxxxxx CRC16 xxxx`, for comparing with `ulani-swift probe` / the PC.
    public static func crcLine(page: Int, frame: Frame) -> String {
        "\(pageTitle(page)) CRC32 \(hex(frame.crc32, digits: 8)) CRC16 \(hex(UInt32(frame.crc16), digits: 4))"
    }

    /// (page, status text, percent) for one push progress event (gui_model.describe).
    public static func describe(_ event: PushEvent) -> (page: Int, text: String, percent: Int) {
        switch event.phase {
        case .start:
            return (event.page, "準備傳送（\(event.index + 1)/\(event.count)）", 0)
        case .sending:
            let percent = event.total > 0 ? event.sent * 100 / event.total : 0
            return (event.page, "傳送中 \(percent)%", percent)
        case .unchanged:
            return (event.page, "已是這張照片，略過", 100)
        case .refreshing:
            return (event.page, "完成（畫面約需 40 秒刷新）", 100)
        case .done:
            return (event.page, "完成", 100)
        }
    }

    /// What the user can do about `error`, or nil when there is nothing to suggest.
    public static func hint(for error: any Error) -> String? {
        switch UlaniError.from(error) {
        case .bondLost:
            "裝置與這台電腦的配對已失效。請到藍牙設定忘記這個裝置，按住裝置按鍵約 5 秒（綠燈閃爍）後重新配對。"
        case .deviceBusy, .noReply:
            "裝置沒有回應（可能正在刷新畫面）。請等一分鐘後再推送一次。"
        case .uploadFailed:
            "裝置回報收到的資料有誤，請再推送一次。"
        case .notFound, .connectFailed:
            "找不到裝置或連不上。請確認：裝置在附近、藍牙已開啟、裝置已與這台電腦配對，且沒有其他手機或電腦正在連線。"
        case .bluetoothUnavailable:
            "藍牙未開啟或未允許本 App 使用藍牙。請到設定開啟。"
        case .linkLost:
            "藍牙連線中斷。請靠近裝置後再推送一次。"
        case .unlockRejected, .unexpectedHeaderReply, .protocolError, nil:
            nil
        }
    }

    /// A short explanation in Chinese, followed by the technical message (gui.friendly).
    public static func friendly(_ error: any Error) -> String {
        let text = String(describing: error)
        guard let hint = hint(for: error) else { return text }
        return "\(hint)\n\n\(text)"
    }

    /// Why a photo could not be turned into a preview; names only the file, never its folder.
    public static func previewError(name: String?, error: any Error) -> String {
        let message = String(describing: error)
        let reason: String
        if message.contains("unsupported image") {
            reason = "不支援的檔案格式"
        } else if message.contains("cannot read") || isFileError(error) {
            reason = "檔案無法開啟或已損壞"
        } else {
            reason = "無法處理這個檔案"
        }
        return "\(name.map { "無法讀取 \($0)" } ?? "無法讀取這張照片")：\(reason)"
    }

    private static func isFileError(_ error: any Error) -> Bool {
        let domain = (error as NSError).domain
        return domain == NSCocoaErrorDomain || domain == NSPOSIXErrorDomain
    }

    private static func hex(_ value: UInt32, digits: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
