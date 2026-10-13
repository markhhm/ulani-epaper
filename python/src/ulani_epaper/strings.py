"""Every text the desktop app shows, in Traditional Chinese (zh) and English (en).

``t(key, **fmt)`` gives a text in the language chosen with ``set_language``; the app starts in
the saved choice or, without one, the system language (``system_language``). English calls the
hardware the "device", never a "calendar": "calendar" is for calendar data (feeds, events).
The English wording follows the macOS app's Strings.swift where the same concept exists. The
pages drawn on the device stay Chinese, and so do the command line's own messages.
shared/LANGUAGE.md is the spec every Paperhue app follows.
"""

from __future__ import annotations

import locale
import sys
from typing import Callable

LANGUAGES = ("zh", "en")

# key: (Traditional Chinese, English). The same {placeholders} in both.
_TEXTS: dict[str, tuple[str, str]] = {
    # --- the language button, page kinds, small helpers --------------------------------------
    "language_toggle": ("English", "中文"),
    "page_photo": ("照片", "Photo"),
    "page_month": ("本日＋月曆", "Today + month"),
    "page_agenda": ("本日行程＋一週行程", "Today + week"),
    "page_todo": ("待辦清單", "To-do"),
    "page_day": ("日", "Day"),
    "page_monthgrid": ("月曆", "Month"),
    "page_board": ("留言板", "Notes board"),
    "page_message": ("大字留言", "Big message"),
    "page_card": ("牌卡", "Card"),
    "page_title": ("第 {n} 頁", "Page {n}"),
    "pages_one": ("{n} 頁", "{n} page"),
    "pages_many": ("{n} 頁", "{n} pages"),
    "list_sep": ("、", ", "),
    "plain": ("{text}", "{text}"),
    "cancel": ("取消", "Cancel"),
    "close": ("關閉", "Close"),
    "delete": ("刪除", "Delete"),
    "colour_label": ("顏色", "Colour"),
    # --- options ---------------------------------------------------------------------------
    "fit_cover": ("填滿畫面（裁切多餘部分）", "Fill the screen (crop the rest)"),
    "fit_contain": ("完整顯示（留白邊）", "Show all (white margins)"),
    "grain_label": ("顆粒感", "Grain"),
    "grain_standard": ("標準", "Standard"),
    "grain_soft": ("柔和", "Soft"),
    "grain_softer": ("更柔和", "Softer"),
    "grain_smoothest": ("最平滑", "Smoothest"),
    # --- the top bar and the device status ---------------------------------------------------
    "device_unknown": ("裝置狀態：尚未讀取", "Device status: not read yet"),
    "device_connecting": ("裝置狀態：連線中…", "Device status: connecting…"),
    "device_unreachable": ("裝置狀態：連不上", "Device status: unreachable"),
    "device_pushed": ("裝置狀態：剛完成推送（按「讀取狀態」可更新）",
                      "Device status: just pushed (press “Read status” to update)"),
    "device_synced": ("裝置狀態：剛完成同步（按「讀取狀態」可更新）",
                      "Device status: just synced (press “Read status” to update)"),
    "device_battery": ("裝置狀態：電量 {level}，目前顯示第 {shown} 頁",
                       "Device status: battery {level}, showing page {shown}"),
    "battery_charging": ("充電中", "charging"),
    "read_info": ("讀取狀態", "Read status"),
    # --- the calendar row ------------------------------------------------------------------------
    "feeds_missing_pkg": ("行事曆：這個版本缺少行事曆套件（pip install \"ulani-epaper[calendar]\"）",
                          "Calendar: this version lacks the calendar package (pip install \"ulani-epaper[calendar]\")"),
    "feeds_none": ("行事曆來源：尚未設定（按「行事曆來源…」加入 iCal 網址）",
                   "Calendar sources: none yet (press “Calendar sources…” to add an iCal address)"),
    "feeds_named": ("行事曆來源：{names}", "Calendar sources: {names}"),
    "feeds_btn": ("行事曆來源…", "Calendar sources…"),
    "notes_btn": ("留言…", "Notes…"),
    "sync_btn": ("立即同步", "Sync now"),
    "schedule_btn": ("每日排程…", "Daily schedule…"),
    "last_sync_none": ("上次同步：尚無紀錄", "Last sync: none yet"),
    "last_sync": ("上次同步：{when} {outcome}", "Last sync: {when} {outcome}"),
    "last_sync_ok": ("成功", "succeeded"),
    "last_sync_failed": ("失敗（{message}）", "failed ({message})"),
    # --- the bottom bar: push and sync progress ---------------------------------------------------
    "push_btn": ("推送到裝置", "Push to device"),
    "summary_idle": ("改好各頁後按「推送到裝置」，有內容的頁面一次送出（行事曆頁會讀取最新行程）；"
                     "只想更新一頁時，按那一頁的「更新這頁」。",
                     "When your pages are ready, press “Push to device” to send every page that has something "
                     "on it (calendar pages get your latest events); “Update this page” sends just that page."),
    "push_start": ("連線並推送中…（正在顯示的那一頁會最後傳）",
                   "Connecting and pushing… (the page on screen goes last)"),
    "push_done": ("完成：{changed}已更新，{same}原本就相同。", "Done: {changed} updated, {same} already the same."),
    "push_done_note": ("完成：{changed}已更新，{same}原本就相同。注意：{warnings}",
                       "Done: {changed} updated, {same} already the same. Note: {warnings}"),
    "push_failed": ("推送失敗，請看錯誤訊息後再試一次。", "Push failed. Read the error message, then try again."),
    "push_failed_title": ("推送失敗", "Push failed"),
    "info_failed_title": ("讀取狀態失敗", "Couldn’t read the status"),
    "show_start": ("正在切換到第 {slot} 頁…", "Switching to page {slot}…"),
    "show_done": ("已切換到第 {slot} 頁，裝置畫面重畫約需 40 秒。",
                  "The device now shows page {slot}. Its screen takes about 40 s to redraw."),
    "show_already": ("裝置已經在顯示第 {slot} 頁。", "The device already shows page {slot}."),
    "show_failed": ("切換頁面失敗，請看錯誤訊息後再試一次。",
                    "Switching the page failed. Read the error message, then try again."),
    "show_failed_title": ("切換頁面失敗", "Couldn’t switch the page"),
    "sync_reading": ("讀取行事曆與待辦事項…", "Reading calendars and to-dos…"),
    "sync_preparing": ("準備留言頁…", "Preparing the notes pages…"),
    "sync_rendered": ("行事曆已讀取，連線並推送中…（正在顯示的那一頁會最後傳）",
                      "Calendars read. Connecting and pushing… (the page on screen goes last)"),
    "sync_done": ("同步完成：{message}", "Sync done: {message}"),
    "sync_failed": ("同步失敗，請看錯誤訊息後再試一次。", "Sync failed. Read the error message, then try again."),
    "sync_failed_title": ("同步失敗", "Sync failed"),
    "close_title": ("仍在傳送", "Still sending"),
    "close_text": ("還在傳送到裝置，現在關閉會中斷傳送。確定要關閉嗎？",
                   "Still sending to the device. Quitting now interrupts the transfer. Quit anyway?"),
    "drop_title": ("照片比照片頁多", "More photos than photo pages"),
    "drop_ask": ("拖進來 {photos} 張照片，但只有 {slots} 頁設為照片。\n要把{names}改成照片嗎？",
                 "You dropped {photos} photos, but only {slots} pages are set to photos.\n"
                 "Turn {names} into photo pages?"),
    "drop_name": ("第 {slot} 頁（{kind}）", "page {slot} ({kind})"),
    "drop_partial": ("只載入了 {n} 張照片：其他頁面設為行事曆。",
                     "Only {n} photos were loaded: the other pages show calendar data."),
    "settings_bad_title": ("設定檔有誤", "Problem with the settings file"),
    "settings_bad": ("{error}\n\n先使用預設值，設定檔修好之前不會儲存任何變更。",
                     "{error}\n\nUsing the defaults for now. Nothing will be saved until the file is fixed."),
    "settings_bad_kept": ("{error}\n\n設定檔有誤，所以沒有儲存這項變更（原檔保持不動）。",
                          "{error}\n\nThe settings file is broken, so this change was not saved (the file is left as it is)."),
    "settings_save_failed_title": ("無法儲存設定", "Couldn’t save the settings"),
    # --- progress on a tile -------------------------------------------------------------------------
    "tile_waiting": ("等待中", "Waiting"),
    "tile_waiting_send": ("等待傳送", "Waiting to send"),
    "tile_unfinished": ("未完成", "Not finished"),
    "tile_reading": ("讀取行事曆中…", "Reading calendars…"),
    "tile_preparing": ("準備留言中…", "Preparing notes…"),
    "progress_start": ("準備傳送（{n}/{count}）", "Getting ready ({n}/{count})"),
    "progress_sending": ("傳送中 {percent}%", "Sending {percent}%"),
    "progress_unchanged": ("已是這張照片，略過", "Already has this photo, skipped"),
    "progress_unchanged_sync": ("內容沒有變化，略過", "Nothing changed, skipped"),
    "progress_refreshing": ("完成（畫面約需 40 秒刷新）", "Done (the screen takes about 40 s to refresh)"),
    "progress_switching": ("切換顯示這一頁（畫面約需 40 秒刷新）",
                           "Switching to this page (the screen takes about 40 s to refresh)"),
    "progress_done": ("完成", "Done"),
    # --- a tile: what it shows, its buttons, its photo ------------------------------------------------
    "show_label": ("顯示", "Show"),
    "show_on_device": ("在裝置上顯示", "Show on device"),
    "update_page": ("更新這頁", "Update this page"),
    "choose_photo": ("選擇照片…", "Choose photo…"),
    "clear": ("清除", "Clear"),
    "adjust_btn": ("調整範圍…", "Adjust crop…"),
    "choose_photo_title": ("選擇第 {n} 頁的照片", "Choose a photo for page {n}"),
    "filetype_images": ("圖片", "Images"),
    "filetype_all": ("所有檔案", "All files"),
    "no_photo": ("尚未選擇照片", "No photo chosen"),
    "unreadable": ("無法讀取這個檔案", "Can’t read this file"),
    "making_preview": ("產生預覽中…", "Making preview…"),
    "preview_ready": ("預覽為裝置實際顯示的 7 色效果", "Preview in the device’s 7 colours"),
    "board_tile_name": ("{kind}（按上方「留言…」新增留言）", "{kind} (add notes with “Notes…” above)"),
    "calendar_tile_name": ("{kind}（來自行事曆來源）", "{kind} (from your calendar sources)"),
    "card_tile_name": ("{kind}（在上方「我的牌卡…」選一張）", "{kind} (pick one in “My cards…” above)"),
    "card_tile": ("{kind}頁\n\n按上方「我的牌卡…」選一張牌卡\n（同步不會更新這一頁）",
                  "{kind} page\n\nPick a card in “My cards…” above\n(a sync never changes this page)"),
    "bg_btn": ("底圖…", "Background…"),
    "bg_choose": ("選擇底圖照片…", "Choose a background photo…"),
    "bg_adjust": ("調整底圖範圍…", "Adjust the background crop…"),
    "bg_clear": ("移除底圖", "Remove the background"),
    "bg_choose_title": ("選擇第 {n} 頁的底圖", "Choose a background for page {n}"),
    "bg_set": ("底圖已設定，按上方「立即同步」套用到裝置", "Background set. Press “Sync now” above to show it on the device"),
    "bg_cleared": ("已移除底圖，按上方「立即同步」套用到裝置",
                   "Background removed. Press “Sync now” above to update the device"),
    "press_sync": ("{kind}\n\n按「推送到裝置」或上方「立即同步」更新",
                   "{kind}\n\nPress “Push to device” or “Sync now” above to update"),
    "notes_unreadable": ("留言檔無法讀取\n\n請按上方「留言…」查看",
                         "The notes file can’t be read\n\nPress “Notes…” above to look"),
    "photo_too_large": ("照片超過 5000 萬像素的上限，請先縮小再選。",
                        "This photo is over the 50-megapixel limit. Shrink it, then choose it again."),
    "preview_error": ("無法讀取 {name}：{why}", "Can’t read {name}: {why}"),
    "why_unsupported": ("不支援的檔案格式（HEIC 請先轉成 JPG）",
                        "unsupported file format (convert HEIC to JPG first)"),
    "why_damaged": ("檔案無法開啟或已損壞", "the file can’t be opened or is damaged"),
    "why_other": ("無法處理這個檔案", "can’t process this file"),
    # --- the crop dialog -------------------------------------------------------------------------------
    "crop_title": ("調整範圍", "Adjust crop"),
    "crop_help": ("拖曳移動範圍；拉四角、滾輪或下方滑桿縮放；方向鍵微調（加 Shift 加快）",
                  "Drag to move the crop; drag a corner, use the mouse wheel or the slider below to zoom; "
                  "arrow keys nudge it (hold Shift to go faster)"),
    "crop_zoom": ("縮放", "Zoom"),
    "crop_reset": ("重設", "Reset"),
    "crop_ok": ("確定", "OK"),
    # --- my cards --------------------------------------------------------------------------------------
    "cards_btn": ("我的牌卡…", "My cards…"),
    "cards_title": ("我的牌卡", "My cards"),
    "cards_help": ("按牌卡下方的「放到第 N 頁」把它放到牌卡頁，再按主視窗的「推送到裝置」或那一頁的「更新這頁」"
                   "送到裝置。勾選牌卡後可編輯、複製、刪除或匯出。",
                   "Click “Put on page N” under a card to put it on a card page, then click “Push to device” in "
                   "the main window, or “Update this page” on that page, to send it. Tick cards to edit, "
                   "duplicate, delete or export them."),
    "cards_none": ("還沒有牌卡：按「新增牌卡…」做一張。", "No cards yet: press “New card…” to make one."),
    "cards_unreadable": ("牌卡檔無法讀取：{detail}", "The cards file can’t be read: {detail}"),
    "card_new": ("新增牌卡…", "New card…"),
    "card_edit": ("編輯…", "Edit…"),
    "card_duplicate": ("複製", "Duplicate"),
    "card_import": ("匯入…", "Import…"),
    "card_export": ("匯出…", "Export…"),
    "card_put": ("放到第 {slot} 頁", "Put on page {slot}"),
    "card_put_menu": ("放到…", "Put on…"),
    "card_put_done": ("已放到第 {slot} 頁，按主視窗的「推送到裝置」或那一頁的「更新這頁」送到裝置。",
                      "Card put on page {slot}. Click “Push to device” in the main window, or “Update this page” "
                      "on that page, to send it."),
    "card_on_pages": ("放在第 {pages} 頁", "On page {pages}"),
    "card_on_no_page": ("沒有放在任何一頁", "Not on a page"),
    "card_unreadable": ("背景圖讀不到", "Can’t read the background photo"),
    "card_pick_one": ("請先勾選一張牌卡。", "Tick one card first."),
    "card_delete_title": ("刪除牌卡", "Delete cards"),
    "card_delete_ask": ("要刪除勾選的 {count} 張牌卡嗎？刪除後無法復原。",
                        "Delete the {count} ticked cards? This can’t be undone."),
    "card_deleted": ("已刪除。", "Deleted."),
    "card_duplicated": ("已複製一張。", "Duplicated."),
    "card_exported": ("已匯出到 {name}。", "Exported to {name}."),
    "card_imported": ("已匯入一張牌卡。", "Card imported."),
    "card_failed_detail": ("無法完成：{detail}", "Couldn’t do that: {detail}"),
    "filetype_cards": ("Paperhue 牌卡", "Paperhue cards"),
    "card_page_title": ("沒有牌卡頁", "No card page"),
    "card_page_ask": ("還沒有任何一頁設為牌卡。要把第 {slot} 頁（{kind}）改成牌卡頁並把牌卡放上去嗎？",
                      "No page is set to Card yet. Turn page {slot} ({kind}) into a card page and put the card on it?"),
    # --- the card editor -----------------------------------------------------------------------------
    "card_editor_new": ("新增牌卡", "New card"),
    "card_editor_edit": ("編輯牌卡", "Edit card"),
    "card_help": ("拖曳文字框移動，拉四角改大小，滾輪改字級。預覽為裝置實際顯示的 7 色效果。",
                  "Drag a text box to move it, drag a corner to resize it, use the mouse wheel for the size. "
                  "The preview shows the device’s 7 colours."),
    "card_background": ("背景", "Background"),
    "card_bg_photo": ("照片", "Photo"),
    "card_photo_btn": ("照片…", "Photo…"),
    "card_add_text": ("新增文字框", "Add text box"),
    "card_delete_text": ("刪除文字框", "Delete text box"),
    "card_text_label": ("文字（最多 {max} 字）", "Text (up to {max} characters)"),
    "card_new_text": ("文字", "Text"),
    "card_size": ("字級", "Size"),
    "card_ink": ("文字顏色", "Text colour"),
    "card_outline": ("外框", "Outline"),
    "card_align": ("對齊", "Align"),
    "align_left": ("靠左", "Left"),
    "align_center": ("置中", "Centre"),
    "align_right": ("靠右", "Right"),
    "card_save": ("儲存", "Save"),
    "card_text_empty": ("第 {n} 個文字框是空的", "Text box {n} is empty"),
    "card_text_too_long": ("第 {n} 個文字框最多 {max} 字（目前 {count} 字）",
                           "Text box {n} can have at most {max} characters (it has {count})"),
    "card_texts_full": ("每張牌卡最多 {max} 個文字框", "A card can have at most {max} text boxes"),
    "card_save_failed": ("無法儲存牌卡：{detail}", "Couldn’t save the card: {detail}"),
    "ink_black": ("黑", "Black"),
    "ink_white": ("白", "White"),
    "ink_green": ("綠", "Green"),
    "ink_blue": ("藍", "Blue"),
    "ink_red": ("紅", "Red"),
    "ink_yellow": ("黃", "Yellow"),
    "ink_orange": ("橙", "Orange"),
    # --- the daily schedule dialog ------------------------------------------------------------------------
    "schedule_title": ("每日自動同步", "Daily automatic sync"),
    "schedule_error_title": ("每日排程", "Daily schedule"),
    "schedule_prompt": ("每天在這些時間讀取行事曆並更新裝置（24 小時制，多個時間用逗號分隔），例如早上一次、下午一次：",
                        "Every day at these times the app reads your calendars and updates the device "
                        "(24-hour time, separate several times with commas), "
                        "for example one in the morning and one in the afternoon:"),
    "schedule_on": ("目前：已啟用，每天 {times}", "Now: on, every day at {times}"),
    "schedule_off": ("目前：未啟用", "Now: off"),
    "schedule_note": ("電腦需要開機並登入 Windows；關機或睡眠時錯過的時間，會在下次開機後補做。",
                      "The computer must be on and signed in to Windows; times missed while it is off or "
                      "asleep are made up the next time it starts."),
    "schedule_apply": ("啟用／更新排程", "Turn on / update"),
    "schedule_remove": ("停用排程", "Turn off"),
    "time_bad_title": ("時間格式不正確", "That time isn’t valid"),
    "time_bad": ("「{part}」不是有效的時間，請用 24 小時制，例如 06:00",
                 "“{part}” isn’t a valid time. Use 24-hour time, for example 06:00"),
    "time_missing": ("請至少輸入一個時間，例如 06:00", "Enter at least one time, for example 06:00"),
    "schedule_failed_title": ("無法建立排程", "Couldn’t set up the schedule"),
    "schedule_remove_failed_title": ("無法停用排程", "Couldn’t turn the schedule off"),
    # --- the notes dialog -----------------------------------------------------------------------------------
    "notes_title": ("留言", "Notes"),
    "notes_no_board": ("還沒有留言頁：請在主視窗任一頁的「顯示」選「留言板」或「大字留言」，留言就會顯示在裝置的那一頁。",
                       "No page shows notes yet: in the main window, set a page’s “Show” to “Notes board” or "
                       "“Big message”, and the notes will appear on that page of the device."),
    "notes_text_label": ("留言內容（最多 {max} 字、{lines} 行）：", "Note (up to {max} characters, {lines} lines):"),
    "note_yellow": ("黃", "Yellow"),
    "note_orange": ("橘", "Orange"),
    "note_green": ("綠", "Green"),
    "note_blue": ("藍", "Blue"),
    "note_red": ("紅", "Red"),
    "notes_post": ("新增留言", "Add note"),
    "notes_hint": ("留言會在你按主視窗的「推送到裝置」或留言頁的「更新這頁」時送到裝置。",
                   "Notes reach the device when you click “Push to device”, or “Update this page” on a notes page."),
    "notes_added": ("已新增留言。", "Note added."),
    "notes_posted": ("已新增的留言（最新的在最上面）：", "Your notes (newest first):"),
    "notes_col_time": ("時間", "Time"),
    "notes_col_text": ("內容", "Text"),
    "notes_clear": ("全部清除", "Clear all"),
    "notes_save_failed": ("無法儲存留言：{detail}", "Couldn’t save the note: {detail}"),
    "notes_pick_first": ("請先在清單中點選要刪除的留言。", "Select the note to delete in the list first."),
    "notes_delete_failed": ("無法刪除：{detail}", "Couldn’t delete: {detail}"),
    "notes_deleted": ("已刪除這則留言。", "Note deleted."),
    "notes_clear_ask": ("要刪除全部 {count} 則留言嗎？刪除後無法復原。",
                        "Delete all {count} notes? This can’t be undone."),
    "notes_clear_failed": ("無法清除：{detail}", "Couldn’t clear: {detail}"),
    "notes_cleared": ("已清除全部留言。", "All notes cleared."),
    "note_empty": ("留言是空的", "The note is empty"),
    "note_too_long": ("留言最多 {max} 字（目前 {count} 字）",
                      "A note can have at most {max} characters (this one has {count})"),
    "note_too_many_lines": ("留言最多 {max} 行", "A note can have at most {max} lines"),
    # --- the calendar sources dialog and form ----------------------------------------------------------------
    "feeds_title": ("行事曆來源", "Calendar sources"),
    "feeds_help": ("每個來源是一個 iCal（.ics）網址，例如 Google 日曆每個日曆的「iCal 格式的私密網址」"
                   "（日曆設定 → 整合日曆）。網址只存在這台電腦的 Windows 認證管理員；程式只讀取，"
                   "也不會把行程內容存在電腦上。說明：docs/CALENDARS.md",
                   "Each source is an iCal (.ics) address, for example a Google Calendar’s “Secret address in "
                   "iCal format” (calendar settings → Integrate calendar). The address is kept only in this "
                   "computer’s Windows Credential Manager; the app only reads it and never stores your events "
                   "on the computer. Help: docs/CALENDARS.md"),
    "feeds_col_name": ("名稱", "Name"),
    "feeds_col_colour": ("顏色", "Colour"),
    "feeds_col_source": ("來源", "Source"),
    "feed_url_lost": ("（網址遺失：請刪除後重新加入）", "(address lost: delete it and add it again)"),
    "feed_add": ("新增…", "Add…"),
    "feed_edit": ("編輯…", "Edit…"),
    "feed_delete_title": ("刪除來源", "Delete source"),
    "feed_delete_ask": ("要刪除「{name}」嗎？\n它的網址也會從這台電腦刪除。",
                        "Delete “{name}”?\nIts address is also removed from this computer."),
    "feed_delete_failed": ("刪除失敗", "Couldn’t delete"),
    "feed_new_title": ("新增行事曆來源", "New calendar source"),
    "feed_edit_title": ("編輯「{name}」", "Edit “{name}”"),
    "feed_name": ("名稱（顯示在頁面上）", "Name (shown on the pages)"),
    "feed_url": ("iCal 網址", "iCal address"),
    "feed_url_keep": ("iCal 網址（留空＝不變）", "iCal address (leave empty to keep it)"),
    "feed_user": ("帳號（需要登入時才填）", "Account (only if it needs a sign-in)"),
    "feed_password": ("密碼 / App 密碼", "Password / app password"),
    "feed_password_keep": ("密碼 / App 密碼（留空＝不變）", "Password / app password (leave empty to keep it)"),
    "feed_hidden": ("網址會隱藏顯示，只存在這台電腦的認證管理員。",
                    "The address is hidden and kept only in this computer’s credential manager."),
    "feed_check_save": ("檢查並儲存", "Check and save"),
    "feed_need_name": ("請輸入名稱，例如「個人」或「學校」。", "Enter a name, for example “Personal” or “School”."),
    "feed_need_url": ("請貼上 iCal 網址。", "Paste the iCal address."),
    "feed_reading": ("正在讀取 {host} …", "Reading {host} …"),
    "feed_unusable": ("無法使用這個網址：{detail}", "Can’t use this address: {detail}"),
    "feed_saved": ("已儲存「{name}」：近期 {events} 個行程、{tasks} 項待辦。",
                   "Saved “{name}”: {events} upcoming events, {tasks} to-dos."),
    "feed_colour_auto": ("自動", "Automatic"),
    "feed_colour_red": ("紅", "Red"),
    "feed_colour_orange": ("橙", "Orange"),
    "feed_colour_yellow": ("黃", "Yellow"),
    "feed_colour_green": ("綠", "Green"),
    "feed_colour_blue": ("藍", "Blue"),
    "feed_colour_black": ("黑", "Black"),
    # --- errors the calendar addresses can give (feeds.py) --------------------------------------------------------
    "fe_space": ("網址中間有空白或換行，請重新複製整段網址",
                 "The address contains spaces or line breaks. Copy the whole address again."),
    "fe_scheme": ("這不是有效的行事曆網址（要以 https:// 或 webcal:// 開頭）",
                  "This isn’t a valid calendar address (it must start with https:// or webcal://)"),
    "fe_credentials": ("網址裡不要放帳號密碼，請分開填在「帳號」「密碼」",
                       "Don’t put an account or password in the address; enter them in the "
                       "“Account” and “Password” fields"),
    "fe_http": ("HTTP {code}（{hint}）", "HTTP {code} ({hint})"),
    "http_400": ("網址無效，或已被重設", "the address is invalid, or it was reset"),
    "http_401": ("需要帳號密碼，或密碼不對", "it needs an account and password, or the password is wrong"),
    "http_403": ("沒有權限", "no permission"),
    "http_404": ("找不到：網址可能已重設或刪除", "not found: the address may have been reset or deleted"),
    "http_410": ("已刪除", "deleted"),
    "http_other": ("伺服器拒絕", "the server refused"),
    "fe_connect": ("無法連線到 {host}（{reason}）", "Can’t connect to {host} ({reason})"),
    "fe_zip": ("收到損壞的壓縮資料", "Received damaged compressed data"),
    "fe_big": ("行事曆大於 {mb} MB，不處理", "The calendar is larger than {mb} MB, so it isn’t processed"),
    "fe_not_ical": ("收到的不是 iCalendar 資料（網址可能不對，或需要登入）",
                    "What came back isn’t iCalendar data (the address may be wrong, or it needs a sign-in)"),
    "fe_none": ("尚未設定行事曆來源", "No calendar sources yet"),
    "default_calendar": ("台灣假日", "Taiwan holidays"),
    "fe_lost": ("{name}：找不到這個來源的網址，請重新加入", "{name}: this source’s address is missing; add it again"),
    "fe_named": ("{name}：{error}", "{name}: {error}"),
    # --- what to do about an error ---------------------------------------------------------------------------------
    "hint_no_feeds": ("還沒有行事曆來源：請按「行事曆來源…」加入 iCal 網址。",
                      "No calendar sources yet: press “Calendar sources…” and add an iCal address."),
    "hint_feed_error": ("無法讀取行事曆來源。請確認網路連線；如果網址已重設，請在「行事曆來源…」更新。",
                        "Can’t read the calendar sources. Check your internet connection; if an address was "
                        "reset, update it in “Calendar sources…”."),
    "hint_not_paired": ("裝置尚未與這台電腦配對。裝置一次只記得一支手機或電腦，和別的手機或電腦配對後，這台電腦的配對就會失效。"
                        "如果以前配對過，請先在 Windows 藍牙設定中移除裝置。然後按住裝置按鍵約 5 秒（綠燈閃爍），"
                        "在 Windows 藍牙設定中配對。",
                        "The device isn’t paired with this computer. It remembers one phone or computer at a time: "
                        "pairing another one unpairs this PC. If it was paired before, remove it in Windows Bluetooth "
                        "settings first. Then hold the device’s button for about 5 s (the light blinks green) and "
                        "pair it in Windows Bluetooth settings."),
    "hint_no_response": ("裝置沒有回應（可能正在刷新畫面）。請等一分鐘後再推送一次。",
                         "The device didn’t respond (it may be refreshing its screen). "
                         "Wait a minute, then push again."),
    "hint_bad_data": ("裝置回報收到的資料有誤，請再推送一次。",
                      "The device says the data it received was damaged. Push again."),
    "hint_not_found": ("找不到裝置或連不上。請確認：裝置在附近、藍牙已開啟、裝置已與這台電腦配對，且沒有其他手機或電腦正在連線。",
                       "Can’t find or connect to the device. Check that it is nearby, Bluetooth is on, the "
                       "device is paired with this computer, and no other phone or computer is connected to it."),
    "hint_link_lost": ("藍牙連線中斷。請靠近裝置後再推送一次。",
                       "The Bluetooth connection dropped. Move closer to the device and push again."),
    # --- what a sync did (syncjob.describe) --------------------------------------------------------------------------
    "sj_no_pages": ("沒有設定成行事曆或待辦的頁面", "No page is set to show calendar data or to-dos"),
    "sj_page": ("第 {slot} 頁 {kind}：{outcome}", "Page {slot} {kind}: {outcome}"),
    "sj_updated": ("已更新", "updated"),
    "sj_unchanged": ("沒有變化", "no change"),
    "sj_drawn": ("已繪製（未推送）", "drawn (not pushed)"),
    "sj_pages_sep": ("；", "; "),
    "sj_events": ("{events} 個行程、{tasks} 項待辦", "{events} events, {tasks} to-dos"),
    "sj_notes": ("{notes} 則留言", "{notes} notes"),
    "sj_with_counts": ("{pages}（{counts}）", "{pages} ({counts})"),
    "sj_warnings": ("{text}。注意：{warnings}", "{text}. Note: {warnings}"),
    "sync_bg_unreadable": ("第 {slot} 頁的背景圖讀不到（{image}），這一頁沒有背景：{error}",
                           "Page {slot}: the background photo ({image}) can’t be read, so the page has none: {error}"),
    "push_no_calendars": ("無法讀取行事曆，行事曆頁這次沒有更新：{error}",
                          "Couldn’t read the calendars, so the calendar pages were not updated this time: {error}"),
}

#: key -> {"zh": ..., "en": ...}
STRINGS: dict[str, dict[str, str]] = {key: {"zh": zh, "en": en} for key, (zh, en) in _TEXTS.items()}

_language = "zh"


def language() -> str:
    return _language


def set_language(lang: str) -> None:
    global _language
    if lang not in LANGUAGES:
        raise ValueError(f"language must be one of {', '.join(LANGUAGES)}, got {lang!r}")
    _language = lang


def t(key: str, **fmt) -> str:
    """The text ``key`` in the current language, with its {placeholders} filled in."""
    return STRINGS[key][_language].format(**fmt)


def later(key: str, **fmt) -> Callable[[], str]:
    """``t(key, **fmt)`` as a function, so a label can draw it again when the language changes."""
    return lambda: t(key, **fmt)


def page_name(kind: str) -> str:
    return t("page_" + kind)


def pages(n: int) -> str:
    """"3 頁" / "3 pages"."""
    return t("pages_one" if n == 1 else "pages_many", n=n)


def system_language() -> str:
    """"zh" if the system's UI language is Chinese, else "en"."""
    try:
        if sys.platform == "win32":
            import ctypes

            primary = ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF  # LANGID -> primary language
            return "zh" if primary == 0x04 else "en"  # LANG_CHINESE
        name = locale.getlocale()[0] or ""
    except Exception:  # no locale information: English is the safe default
        return "en"
    return "zh" if name.lower().startswith("zh") else "en"
