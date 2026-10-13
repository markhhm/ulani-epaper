import Foundation
import PaperhueAgenda
import PaperhuePages
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
        case deviceUnknown, deviceConnecting, deviceUnreachable, deviceJustPushed, deviceJustSynced, readInfo
        case batteryCharging
        // Calendar row
        case feedsNone, feedsButton, notesButton, syncButton, scheduleButton
        // Options
        case fitLabel, fitCover, fitContain
        case grainLabel, grainStandard, grainSoft, grainSofter, grainSmoothest
        // Tiles
        case choosePhoto, chooseFile, clear, updatePage, showOnDevice, noPhoto, unreadable, rendering, previewReady
        case showLabel, kindPhoto, kindMonth, kindAgenda, kindTodo, kindDay, kindMonthGrid, kindBoard, kindMessage
        case notesUnreadableTile
        case reading, notUpdated, progressNothingChanged
        case backgroundMenu, backgroundAdjust, backgroundRemove, backgroundSet, backgroundCleared
        case waiting, unfinished
        case progressUnchanged, progressRefreshing, progressSwitching, progressDone
        case previewUnsupported, previewDamaged, previewUnprocessable, photoTooLarge
        // Crop (shared/CROP.md, Editor)
        case adjustCrop, adjustCropHelp, previewHelp
        case cropFrame, cropHint, cropZoom, cropNoZoom, cropReset, cropResetHelp, cancel, confirm
        case cropMoveLeft, cropMoveRight, cropMoveUp, cropMoveDown
        // Bottom bar
        case push
        case summaryIdle, summaryPushing, summaryFailed
        case summaryReading, summarySyncing, summarySyncFailed, summaryNothingSent
        // Alerts
        case pushFailedTitle, syncFailedTitle, infoFailedTitle, showFailedTitle, ok
        // 留言 (shared/BOARD.md)
        case notesTitle, notesNoBoard, notesIntro, notesAdd, notesListTitle, notesEmpty, notesDelete, notesClear
        case notesClearConfirm, noteYellow, noteOrange, noteGreen, noteBlue, noteRed, done
        // 行事曆來源 (shared/AGENDA.md)
        case feedsTitle, feedsIntro, feedsEmpty, feedName, feedNamePrompt, feedAddress, feedUser, feedPassword
        case feedColour, colourAuto, colourRed, colourOrange, colourYellow, colourGreen, colourBlue, colourBlack
        case feedAdd, feedChecking, feedRemove
        // 每日排程
        case scheduleTitle, schedulePrompt, scheduleAddTime, scheduleRemoveTime, scheduleNote, scheduleApply
        case scheduleTurnOff, scheduleStateOff, scheduleApproval, lastSyncNone
        case hintFeedError, feedEdit, feedSave, feedAddressKeep, feedPasswordKeep, feedAddressLost
        case notesAdded, notesDeleted, notesCleared
        case dropTitle, dropConvert, dropKeep
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
        case .deviceJustSynced:
            pick("裝置狀態：剛完成同步（按「讀取狀態」可更新）", "Device status: just synced (press “Read status” to update)")
        case .readInfo: pick("讀取狀態", "Read status")

        case .feedsNone:
            pick("行事曆來源：尚未設定，行事曆頁先顯示台灣假日（按「行事曆來源…」加入 iCal 網址）",
                 "Calendar sources: none yet, so calendar pages show Taiwan holidays "
                 + "(press “Calendar sources…” to add an iCal address)")
        case .feedsButton: pick("行事曆來源…", "Calendar sources…")
        case .notesButton: pick("留言…", "Notes…")
        case .syncButton: pick("立即同步", "Sync now")
        case .scheduleButton: pick("每日排程…", "Daily schedule…")
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
        case .updatePage: pick("更新這頁", "Update this page")
        case .showLabel: pick("顯示", "Show")
        case .kindPhoto: pick("照片", "Photo")
        case .kindMonth: pick("本日＋月曆", "Today + month")
        case .kindAgenda: pick("本日行程＋一週行程", "Today + week")
        case .kindTodo: pick("待辦清單", "To-do")
        case .kindDay: pick("日", "Day")
        case .kindMonthGrid: pick("月曆", "Month")
        case .kindBoard: pick("留言板", "Notes board")
        case .kindMessage: pick("大字留言", "Big message")
        case .notesUnreadableTile:
            pick("留言檔無法讀取\n\n請按上方「留言…」查看", "The notes file can’t be read\n\nPress “Notes…” above to look")
        case .reading: pick("讀取行事曆中…", "Reading calendars…")
        case .notUpdated: pick("沒有更新", "Not updated")
        case .progressNothingChanged: pick("內容沒有變化，略過", "Nothing changed, skipped")
        case .backgroundMenu: pick("底圖…", "Background…")
        case .backgroundAdjust: pick("調整底圖範圍…", "Adjust the background crop…")
        case .backgroundRemove: pick("移除底圖", "Remove the background")
        case .backgroundSet:
            pick("底圖已設定，推送或同步時會畫上這一頁", "Background set: the next push or sync draws this page on it")
        case .backgroundCleared:
            pick("已移除底圖，推送或同步時會更新裝置", "Background removed: the next push or sync updates the device")
        case .showOnDevice: pick("在裝置上顯示", "Show on device")
        case .noPhoto: pick("尚未選擇照片", "No photo chosen")
        case .unreadable: pick("無法讀取這個檔案", "Can’t read this file")
        case .rendering: pick("產生預覽中…", "Making preview…")
        case .previewReady: pick("預覽為裝置實際顯示的 7 色效果", "Preview in the device’s 7 colours")
        case .waiting: pick("等待中", "Waiting")
        case .unfinished: pick("未完成", "Not finished")
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
        case .summaryIdle:
            pick("設定好每一頁後按「推送到裝置」：照片頁送出照片，行事曆頁會先讀取行事曆，留言頁畫出留言。"
                 + "正在顯示的那一頁會最後傳，全部約需 2 分鐘。",
                 "Set up each page, then press “Push to device”: photo pages send their photo, calendar pages "
                 + "read your calendars first, notes pages draw your notes. The page on screen goes last; "
                 + "it all takes about 2 minutes.")
        case .summaryReading: pick("讀取行事曆與待辦事項…", "Reading calendars and to-dos…")
        case .summarySyncing:
            pick("行事曆已讀取，連線並推送中…（正在顯示的那一頁會最後傳）",
                 "Calendars read. Connecting and pushing… (the page on screen goes last)")
        case .summarySyncFailed:
            pick("同步失敗，請看錯誤訊息後再試一次。", "Sync failed. Read the error message, then try again.")
        case .summaryNothingSent: pick("沒有送出任何一頁。", "No page was sent.")
        case .summaryPushing:
            pick("連線並推送中…（正在顯示的那一頁會最後傳）", "Connecting and pushing… (the page on screen goes last)")
        case .summaryFailed: pick("推送失敗，請看錯誤訊息後再試一次。", "Push failed. Read the error message, then try again.")

        case .pushFailedTitle: pick("推送失敗", "Push failed")
        case .syncFailedTitle: pick("同步失敗", "Sync failed")
        case .infoFailedTitle: pick("讀取狀態失敗", "Couldn’t read the status")
        case .showFailedTitle: pick("無法在裝置上顯示這一頁", "Couldn’t show the page on the device")
        case .ok: pick("好", "OK")

        case .notesTitle: pick("留言", "Notes")
        case .notesNoBoard:
            pick("還沒有留言頁：請在主視窗任一頁的「顯示」選「留言板」或「大字留言」，留言就會顯示在裝置的那一頁。",
                 "No notes page yet: set a page’s “Show” to “Notes board” or “Big message” in the main window, "
                 + "and the notes appear on that page of the device.")
        case .notesIntro:
            pick("新增或刪除留言只會存在這台電腦；按「推送到裝置」或留言頁的「更新這頁」才會送到裝置。",
                 "Adding or deleting notes only saves them on this Mac; press “Push to device” or the notes "
                 + "page’s “Update this page” to send them to the device.")
        case .notesAdd: pick("新增留言", "Add note")
        case .notesListTitle: pick("已張貼的留言（最新的在最上面）：", "Posted notes (newest first):")
        case .notesEmpty: pick("還沒有留言", "No notes yet")
        case .notesDelete: pick("刪除", "Delete")
        case .notesClear: pick("全部清除", "Clear all")
        case .notesClearConfirm: pick("全部清除", "Clear all")
        case .noteYellow: pick("黃", "Yellow")
        case .noteOrange: pick("橘", "Orange")
        case .noteGreen: pick("綠", "Green")
        case .noteBlue: pick("藍", "Blue")
        case .noteRed: pick("紅", "Red")
        case .done: pick("完成", "Done")

        case .feedsTitle: pick("行事曆來源", "Calendar sources")
        case .feedsIntro:
            pick("貼上行事曆的 iCal 網址（Google 日曆的「私人網址」、Outlook、iCloud 公開行事曆）。網址等同密碼，"
                 + "只存在這台 Mac 的鑰匙圈，畫面上只顯示網站名稱。",
                 "Paste a calendar’s iCal address (Google Calendar’s secret address, Outlook, an iCloud public "
                 + "calendar). The address is a password: it is kept only in this Mac’s Keychain, and only the "
                 + "site’s name is shown.")
        case .feedsEmpty:
            pick("還沒有行事曆來源。沒有來源時，行事曆頁會顯示台灣假日。",
                 "No calendar sources yet. Without one, calendar pages show Taiwan holidays.")
        case .feedName: pick("名稱", "Name")
        case .feedNamePrompt: pick("留空則用行事曆自己的名稱", "Leave empty to use the calendar’s own name")
        case .feedAddress: pick("iCal 網址", "iCal address")
        case .feedUser: pick("帳號（選填）", "User name (optional)")
        case .feedPassword: pick("密碼（選填）", "Password (optional)")
        case .feedColour: pick("顏色", "Colour")
        case .colourAuto: pick("自動", "Automatic")
        case .colourRed: pick("紅", "Red")
        case .colourOrange: pick("橘", "Orange")
        case .colourYellow: pick("黃", "Yellow")
        case .colourGreen: pick("綠", "Green")
        case .colourBlue: pick("藍", "Blue")
        case .colourBlack: pick("黑", "Black")
        case .feedAdd: pick("檢查並加入", "Check and add")
        case .feedChecking: pick("檢查中…", "Checking…")
        case .feedRemove: pick("移除", "Remove")

        case .scheduleTitle: pick("每日自動同步", "Daily automatic sync")
        case .schedulePrompt:
            pick("每天在這些時間讀取行事曆，並更新裝置上的行事曆頁，例如早上一次、下午一次：",
                 "Every day at these times, read your calendars and update the calendar pages on the device, "
                 + "e.g. once in the morning and once in the afternoon:")
        case .scheduleAddTime: pick("加入這個時間", "Add this time")
        case .scheduleRemoveTime: pick("移除", "Remove")
        case .scheduleNote:
            pick("Mac 需要開機並登入；睡眠或關機時錯過的時間，會在下次醒來或登入後補做一次。只更新行事曆頁。",
                 "The Mac must be on and logged in; a time missed while it slept or was off is made up once "
                 + "when it wakes or you log in. Only the calendar pages are updated.")
        case .scheduleApply: pick("啟用／更新排程", "Turn on / update")
        case .scheduleTurnOff: pick("停用排程", "Turn off")
        case .scheduleStateOff: pick("目前：未啟用", "Now: off")
        case .scheduleApproval:
            pick("請到「系統設定 › 一般 › 登入項目」允許紙彩在背景執行，排程才會生效。",
                 "Allow Paperhue in System Settings › General › Login Items, or the schedule won’t run.")
        case .lastSyncNone: pick("上次同步：尚無紀錄", "Last sync: none yet")
        case .hintFeedError:
            pick("無法讀取行事曆來源。請確認網路連線；如果網址已重設，請在「行事曆來源…」更新。",
                 "Can’t read the calendar sources. Check your internet connection; if an address was reset, "
                 + "update it in “Calendar sources…”.")
        case .feedEdit: pick("編輯…", "Edit…")
        case .feedSave: pick("檢查並儲存", "Check and save")
        case .feedAddressKeep: pick("iCal 網址（留空＝不變）", "iCal address (leave empty to keep it)")
        case .feedPasswordKeep: pick("密碼（留空＝不變）", "Password (leave empty to keep it)")
        case .feedAddressLost: pick("（網址遺失：請刪除後重新加入）", "(address lost: delete it and add it again)")
        case .notesAdded: pick("已新增留言。", "Note added.")
        case .notesDeleted: pick("已刪除這則留言。", "Note deleted.")
        case .notesCleared: pick("已清除全部留言。", "All notes cleared.")
        case .dropTitle: pick("照片比照片頁多", "More photos than photo pages")
        case .dropConvert: pick("改成照片頁", "Turn them into photo pages")
        case .dropKeep: pick("不要", "Don’t")
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

    public func pageKind(_ kind: PageKind) -> String {
        switch kind {
        case .photo: self[.kindPhoto]
        case .month: self[.kindMonth]
        case .agenda: self[.kindAgenda]
        case .todo: self[.kindTodo]
        case .day: self[.kindDay]
        case .monthgrid: self[.kindMonthGrid]
        case .board: self[.kindBoard]
        case .message: self[.kindMessage]
        }
    }

    /// The calendar row: the sources' names, or that there is none.
    public func feedsLine(_ feeds: [Feed]) -> String {
        guard !feeds.isEmpty else { return self[.feedsNone] }
        let names = feeds.map(\.name).joined(separator: pick("、", ", "))
        return pick("行事曆來源：\(names)", "Calendar sources: \(names)")
    }

    /// A calendar tile before its first drawing.
    public func calendarPlaceholder(_ kind: PageKind) -> String {
        pick("\(pageKind(kind))\n\n推送或同步時讀取行事曆並畫出這一頁",
             "\(pageKind(kind))\n\nDrawn from your calendars when you push or sync")
    }

    public func calendarTileName(_ kind: PageKind) -> String {
        pick("\(pageKind(kind))（來自行事曆來源）", "\(pageKind(kind)) (from your calendar sources)")
    }

    public func boardTileName(_ kind: PageKind) -> String {
        pick("\(pageKind(kind))（按上方「留言…」編輯）", "\(pageKind(kind)) (edit with “Notes…” above)")
    }

    /// Pages left out of a push, and why.
    public func skipped(_ skipped: PushViewModel.Skipped) -> String {
        let list = skipped.pages.map(String.init)
        return switch language {
        case .chinese: "第 \(list.joined(separator: "、")) 頁沒有更新：\(problem(skipped.problem))"
        case .english: "\(list.count == 1 ? "Page" : "Pages") \(list.joined(separator: ", ")) "
            + "\(list.count == 1 ? "wasn’t" : "weren’t") updated: \(problem(skipped.problem))"
        }
    }

    /// A calendar sources or notes error in the interface language; any other error's message.
    public func problem(_ problem: Problem) -> String {
        switch problem {
        case .feed(let error): error.message(inChinese: language == .chinese)
        case .note(let error): error.message(inChinese: language == .chinese)
        case .other(let detail): detail
        }
    }

    /// "同步完成：第 1 頁 本日＋月曆：已更新；第 3 頁 待辦清單：沒有變化（3 個行程、2 項待辦）"
    /// (Python: sync_done with the sync job's message).
    public func syncDone(_ done: PushViewModel.SyncDone) -> String {
        let pages = done.pages.map { p in
            pick("第 \(p.page) 頁 \(pageKind(p.kind))：\(p.changed ? "已更新" : "沒有變化")",
                 "Page \(p.page) \(pageKind(p.kind)): \(p.changed ? "updated" : "no change")")
        }.joined(separator: pick("；", "; "))
        let counts = pick("\(done.events) 個行程、\(done.tasks) 項待辦",
                          "\(done.events) \(done.events == 1 ? "event" : "events"), "
                          + "\(done.tasks) \(done.tasks == 1 ? "to-do" : "to-dos")")
        return pick("同步完成：\(pages)（\(counts)）", "Sync done: \(pages) (\(counts))")
    }

    public func feedSaved(name: String, events: Int?, tasks: Int?) -> String {
        guard let events, let tasks else { return pick("已儲存「\(name)」。", "Saved “\(name)”.") }
        return pick("已儲存「\(name)」：近期 \(events) 個行程、\(tasks) 項待辦。",
                    "Saved “\(name)”: \(events) upcoming \(events == 1 ? "event" : "events"), "
                    + "\(tasks) \(tasks == 1 ? "to-do" : "to-dos").")
    }

    /// 照片比照片頁多: dropped more photos than there are photo pages.
    public func dropAsk(photos: Int, slots: Int, convert: [(page: Int, kind: PageKind)]) -> String {
        let names = convert.map { pick("第 \($0.page) 頁（\(pageKind($0.kind))）", "page \($0.page) (\(pageKind($0.kind)))") }
            .joined(separator: pick("、", ", "))
        return pick("拖進來 \(photos) 張照片，但只有 \(slots) 頁設為照片。\n要把\(names)改成照片嗎？",
                    "You dropped \(photos) photos, but only \(slots) \(slots == 1 ? "page is" : "pages are") set to "
                    + "photos.\nTurn \(names) into photo pages?")
    }

    public func dropPartial(_ loaded: Int) -> String {
        pick("只載入了 \(loaded) 張照片：其他頁面不是照片頁。",
             "Only \(loaded) \(loaded == 1 ? "photo was" : "photos were") loaded: the other pages aren’t photo pages.")
    }

    public func noteColour(_ colour: NoteColour) -> String {
        switch colour {
        case .yellow: self[.noteYellow]
        case .orange: self[.noteOrange]
        case .green: self[.noteGreen]
        case .blue: self[.noteBlue]
        case .red: self[.noteRed]
        }
    }

    /// "" (automatic) or a panel colour name of `Feed.colours`.
    public func feedColour(_ name: String) -> String {
        switch name {
        case "red": self[.colourRed]
        case "orange": self[.colourOrange]
        case "yellow": self[.colourYellow]
        case "green": self[.colourGreen]
        case "blue": self[.colourBlue]
        case "black": self[.colourBlack]
        default: self[.colourAuto]
        }
    }

    public func notesTextLabel() -> String {
        pick("留言內容（最多 \(Note.maxText) 字、\(Note.maxLines) 行）：",
             "Note (up to \(Note.maxText) characters, \(Note.maxLines) lines):")
    }

    /// The note's length against the limit, "12/300".
    public func noteCount(_ text: String) -> String { "\(Note.normalize(text).count)/\(Note.maxText)" }

    public func notesClearAsk(_ count: Int) -> String {
        pick("要刪除全部 \(count) 則留言嗎？刪除後無法復原。",
             count == 1 ? "Delete the note? This can’t be undone." : "Delete all \(count) notes? This can’t be undone.")
    }

    public func feedAdded(name: String, events: Int, tasks: Int) -> String {
        pick("已加入「\(name)」：近期 \(events) 個行程、\(tasks) 項待辦。",
             "Added “\(name)”: \(events) upcoming \(events == 1 ? "event" : "events"), "
             + "\(tasks) \(tasks == 1 ? "to-do" : "to-dos").")
    }

    public func feedRemoveAsk(_ name: String) -> String {
        pick("要移除「\(name)」嗎？之後要再用，得重新貼上網址。",
             "Remove “\(name)”? To use it again you’ll have to paste its address again.")
    }

    /// Calendar pages drawn on white because their background photo could not be read.
    public func lostBackgrounds(_ pages: [Int]) -> String {
        let list = pages.map(String.init)
        return pick("第 \(list.joined(separator: "、")) 頁的底圖讀不到，這次沒有底圖；請重新選擇底圖照片。",
                    "The background photo of page \(list.joined(separator: ", ")) can’t be read, so it was drawn "
                    + "without one; choose the background photo again.")
    }

    public func scheduleOn(_ times: [String]) -> String {
        pick("目前：已啟用，每天 \(times.joined(separator: "、"))", "Now: on, every day at \(times.joined(separator: ", "))")
    }

    public func lastSync(_ outcome: ScheduledSync.Outcome?) -> String {
        guard let outcome else { return self[.lastSyncNone] }
        let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: outcome.at)
        let when = String(format: "%02d/%02d %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        let message = outcome.failure.map { String($0.prefix(60)) }  // Python: message[:60]
        return switch (language, message) {
        case (.chinese, nil): "上次同步：\(when) 成功"
        case (.chinese, let message?): "上次同步：\(when) 失敗（\(message)）"
        case (.english, nil): "Last sync: \(when) succeeded"
        case (.english, let message?): "Last sync: \(when) failed (\(message))"
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

    public func deviceStatus(_ status: CalendarStatus) -> String {
        let battery = status.battery
        let level = battery.charging ? self[.batteryCharging] : "\(battery.level.map(String.init) ?? "?")/5"
        return pick("裝置狀態：電量 \(level)，目前顯示第 \(status.shown) 頁",
                    "Device status: battery \(level), showing page \(status.shown)")
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
        case .reading: self[.summaryReading]
        case .syncing: self[.summarySyncing]
        case .syncDone(let done): syncDone(done)
        case .syncFailed: self[.summarySyncFailed]
        case .nothingSent: self[.summaryNothingSent]
        }
    }

    public func deviceStatus(_ status: PushViewModel.DeviceStatus) -> String {
        switch status {
        case .unknown: self[.deviceUnknown]
        case .connecting: self[.deviceConnecting]
        case .unreachable: self[.deviceUnreachable]
        case .justPushed: self[.deviceJustPushed]
        case .justSynced: self[.deviceJustSynced]
        case .status(let status): deviceStatus(status)
        case .alreadyShowing(let page): pick("裝置已經在顯示第 \(page) 頁。", "The device already shows page \(page).")
        case .switched(let page):
            pick("已切換到第 \(page) 頁，裝置畫面重畫約需 40 秒。",
                 "The device now shows page \(page). Its screen takes about 40 s to redraw.")
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
        case .reading: self[.reading]
        case .notUpdated: self[.notUpdated]
        case .backgroundSet: self[.backgroundSet]
        case .backgroundCleared: self[.backgroundCleared]
        }
    }

    public func alertTitle(_ alert: PushViewModel.Alert) -> String { failureTitle(alert.job) }

    public func alertMessage(_ alert: PushViewModel.Alert) -> String {
        switch alert.problem {
        case .other: friendly(hint: alert.hint, detail: alert.detail)
        // calendar sources: the hint, then the problem in the interface language
        case .feed: "\(self[.hintFeedError])\n\n\(problem(alert.problem))"
        case .note: problem(alert.problem)
        }
    }

    private func failureTitle(_ job: PushViewModel.Job) -> String {
        switch job {
        case .push: self[.pushFailedTitle]
        case .sync: self[.syncFailedTitle]
        case .info: self[.infoFailedTitle]
        case .show: self[.showFailedTitle]
        }
    }

    /// "1 page", "2 pages".
    private func pages(_ count: Int) -> String { count == 1 ? "1 page" : "\(count) pages" }
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
