# 把行事曆與待辦事項放到裝置上（iCal 網址）

裝置的任何一頁都可以設成「月曆」「一週行程」或「待辦清單」，內容來自你自己的行事曆的
**iCal（.ics）網址**，每天定時或手動更新。

- **不依賴任何第三方**：不用 Google 或其他公司的 API、不用建立雲端專案、不用授權登入。
  程式只是定時下載你貼上的網址，跟訂閱行事曆一樣。
- **只讀取**：程式不會修改你的行事曆。
- **不在電腦上留內容**：行程與待辦下載、畫好、傳到裝置後就丟掉，不寫入任何檔案。
- **網址就是密碼**：拿到私密網址的人就能看你的整本行事曆。程式把網址存在 Windows
  認證管理員（不是一般檔案），畫面、記錄與錯誤訊息只顯示主機名稱（例如
  `calendar.google.com`），不顯示完整網址。

## 一、加入來源

**桌面程式**：按「行事曆來源…」→「新增…」→ 填名稱（顯示在頁面上，例如「個人」「學校」）、
貼上網址、選顏色 →「檢查並儲存」。程式會先下載一次，確定是行事曆才存起來，並告訴你
近期有幾個行程、幾項待辦。

**指令列**：

```
ulani feeds add 個人            # 會請你貼上網址（不顯示、不會留在指令歷史）
ulani feeds add 家務 --user 帳號   # 需要帳號密碼的來源（例如 Nextcloud），會再問密碼
ulani feeds                    # 列出來源（只顯示主機）
ulani feeds test               # 立刻下載每個來源，看內容是否正常
ulani feeds edit 個人 --color green
ulani feeds edit 個人 --url      # 網址重設後換新網址
ulani feeds remove 個人          # 同時從認證管理員刪除網址
```

可以加很多個來源（例如個人、學校、家人），每個來源一種顏色。任一來源讀不到時，
這次同步就整個不推送（以免頁面少了一本行事曆卻看不出來），並告訴你是哪一個。

## 二、各家行事曆的網址

### Google 日曆（每個日曆各有一個網址）

1. 電腦瀏覽器開 <https://calendar.google.com/> → 右上角齒輪 →「設定」。
2. 左側「我的日曆的設定」→ 點要放上裝置的那個日曆。
3. 往下到「整合日曆」→ **「iCal 格式的私密網址」** → 複製。
   （不是「iCal 格式的公開網址」：那個只有日曆設成公開才有內容。）
4. 每個日曆重複一次（例如個人、家庭、工作）。

- 你**拒絕**的邀請也在這個網址裡；如果是日曆本人的私密網址，程式會自動略過你拒絕的行程。
- 按「重設」會讓舊網址失效（程式會顯示 HTTP 400/404），把新網址用「編輯」貼上即可。
- **學校或公司帳號**（Google Workspace）可能看不到「私密網址」：管理員可以關掉這個功能
  （外部分享需允許「分享所有資訊」）。看不到時只能請管理員開放，或改用個人帳號。
- 網址的內容由 Google 產生，修改行程後可能要等一段時間才會出現在網址裡。

### Outlook.com / Microsoft 365

設定 →「行事曆」→「共用行事曆」→「發佈行事曆」→ 選行事曆與「可以檢視所有詳細資料」→
「發佈」→ 複製 **ICS** 連結。（公司帳號若沒有這個選項，是管理員沒開放匿名發佈。）

### Apple iCloud

iCloud 只有「公開行事曆」連結（icloud.com/calendar → 行事曆旁的資訊鈕 → 公開行事曆 → 拷貝），
**任何拿到連結的人都看得到**。介意的話不要用。

### 其他

- **Fastmail**：設定 → Calendars → Edit & share → Publish →「Full event details」。
- **Zoho Calendar**：行事曆設定 → Sharing and permissions → Private URL → iCal。
- **Proton Calendar**（付費方案）：設定 → 行事曆 → Share with anyone → Full view 連結。
  Proton 說更新可能要幾個小時。
- **台灣國定假日**（公開）：
  `https://calendar.google.com/calendar/ical/zh-tw.taiwan%23holiday%40group.v.calendar.google.com/public/basic.ics`
  （Google 提供，偶有錯誤，也不含補班日。）

## 三、待辦事項

待辦頁讀取來源裡的 **VTODO**（標準的 iCalendar 待辦）。已完成或已取消的會自動略過；
有期限的依日期排序，逾期的以紅色標示。

**可以用的**：

- **Nextcloud Tasks**（推薦）：在 Nextcloud 建一個「應用程式密碼」，來源網址填
  `https://你的主機/remote.php/dav/calendars/帳號/清單名稱/?export&componentType=VTODO`，
  帳號填 Nextcloud 帳號、密碼填應用程式密碼。（網址後面不要加 start、end 或 expand。）
- **Radicale**、**Baïkal**（自架 CalDAV）：清單的 CalDAV 網址＋帳號密碼。Baïkal 預設用 Digest
  驗證，要在管理介面改成 Basic。
- 其他提供 CalDAV 與應用程式密碼、用 GET 就能下載整個清單的服務。

**不支援的**（這些服務沒有提供 iCal/CalDAV 的待辦存取）：Google Tasks、Apple 提醒事項、
Microsoft To Do、Proton。Todoist 與 TickTick 的「行事曆訂閱」會把有日期的待辦變成**行程**，
可以當作行事曆來源加入，但它們會出現在月曆／一週行程頁，不在待辦頁。

## 四、更新時機

- **立即同步**：桌面程式按「立即同步」，或 `ulani sync`。
- **每天定時**：桌面程式「每日排程…」，或 `ulani schedule install --times 06:00 12:00 18:00`。
  這會在 Windows「工作排程器」建立工作 `Paperhue Sync`：
  - 只在你登入 Windows 時執行（需要你的藍牙配對與認證管理員裡的網址）。
  - 關機或睡眠時錯過的時間，會在下次開機後補做；剛開機時網路或藍牙還沒好，會隔 2 分鐘重試。
  - 內容沒變的頁面，裝置會自己略過，不會重刷畫面。頁面上的「更新於」只寫日期，
    所以同一天內只有行程開始或結束、或資料真的變了，才會重畫。
  - 結果（時間、哪幾頁更新了、幾個行程、幾項待辦——不含任何標題）記在
    `%APPDATA%\ulani-epaper\sync-log.jsonl`，桌面程式顯示「上次同步」。
  - 停用：「每日排程…」→「停用排程」，或 `ulani schedule remove`。

## 常見問題

| 狀況 | 原因與處理 |
|---|---|
| HTTP 400 或 404 | 網址被重設或刪除。到原服務複製新網址，用「編輯」貼上。 |
| HTTP 401 | 需要帳號密碼，或密碼錯了（Nextcloud 請用應用程式密碼）。 |
| 「收到的不是 iCalendar 資料」 | 貼成了網頁網址或公開網址；請用「iCal / ICS」網址。 |
| 學校帳號找不到「私密網址」 | 管理員關閉了；請管理員開放，或改用個人帳號。 |
| 剛改的行程沒出現 | 服務端的網址還沒更新（Google、Proton 可能延遲）；稍後再同步。 |
| 行程標題的表情符號不見了 | 頁面字型（思源黑體）沒有表情符號，會略過；整個標題都是表情符號時顯示「（無法顯示的標題）」。 |
| 推送照片時「找不到裝置或連不上」，剛好是排程時間 | 裝置一次只能有一個連線：排程同步正在傳送。稍等再推；反過來排程遇到你正在推送，會在 2 分鐘後自動重試。 |

---

## English summary

Any page can show a month calendar, a week agenda or a to-do list from your own **iCal (.ics)
addresses**: no third-party API, no cloud project, no sign-in. Add them in the desktop app
("行事曆來源…") or with `ulani feeds add NAME` (the address is asked for hidden). The address is
a secret: it is kept in the OS credential store and only its host is ever shown. Nothing fetched
is stored on disk.

- Google Calendar: Settings → the calendar → Integrate calendar → "Secret address in iCal
  format" (one per calendar; Workspace admins can hide it). Declined invitations are left out.
- Outlook: Settings → Calendar → Shared calendars → Publish a calendar → ICS link.
- iCloud only has public links. Fastmail, Zoho and Proton have private links.
- To-dos (VTODO): Nextcloud Tasks (`…/remote.php/dav/calendars/USER/LIST/?export&componentType=VTODO`
  with an app password), Radicale, Baïkal (switch it to Basic auth). Google Tasks, Apple
  Reminders, Microsoft To Do and Proton offer no iCal/CalDAV access to tasks.
- `ulani sync` now, `ulani schedule install` daily; unchanged pages are skipped by the device.
