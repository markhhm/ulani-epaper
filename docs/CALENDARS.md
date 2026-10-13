# 把行事曆與待辦事項放到裝置上（iCal 網址）

裝置的任何一頁都可以設成「本日＋月曆」「本日行程＋一週行程」「待辦清單」「日」或「月曆」，內容來自你自己的行事曆的
**iCal（.ics）網址**，可以手動或每天定時更新。

- **不依賴任何第三方**：不用 Google 或其他公司的 API、不用建立雲端專案、不用授權登入。
  紙彩只是下載你貼上的網址，跟訂閱行事曆一樣。
- **只讀取**：紙彩不會修改你的行事曆。
- **不在電腦上留內容**：行程與待辦下載、畫好、傳到裝置後就丟掉，不寫入任何檔案。
- **網址就是密碼**：拿到私密網址的人就能看你的整本行事曆，所以只貼到紙彩裡，不要傳給別人。
  紙彩把網址存在 Windows 認證管理員（不是一般檔案），畫面、紀錄與錯誤訊息只顯示主機名稱
  （例如 `calendar.google.com`），不顯示完整網址。

本文用紙彩的中文標籤；介面切換成 English 時，各按鈕的英文名稱見文末的 English summary。

## 一、取得 iCal 網址

### Google 日曆（每個日曆各有一個網址）

1. 用電腦瀏覽器開 <https://calendar.google.com/>（手機 App 沒有這個設定）→ 右上角齒輪 →「設定」。
2. 左側「我的日曆的設定」→ 點要放上裝置的那個日曆。
3. 往下到「整合日曆」→ **「iCal 格式的私密網址」** → 按旁邊的複製按鈕。
   （不是「iCal 格式的公開網址」：那個只有日曆設成公開才有內容。）
4. 每個日曆重複一次（例如個人、家庭、工作），在紙彩裡各加成一個來源。

- 你**拒絕**的邀請也在這個網址裡；如果是你自己主要日曆的私密網址，紙彩會自動略過你拒絕的行程。
- 按「重設」會讓舊網址失效（紙彩會顯示 HTTP 400 或 404），把新網址用「編輯…」貼上即可。
  懷疑網址外流時，也可以用「重設」讓舊網址作廢。
- **學校或公司帳號**（Google Workspace）可能看不到「私密網址」：管理員可以關掉這個功能
  （外部分享需允許「分享所有資訊」）。看不到時只能請管理員開放，或改用個人帳號。
- 網址的內容由 Google 產生，修改行程後可能要等一段時間才會出現在網址裡。

### Apple iCloud 行事曆

iCloud 沒有私密網址，只有「公開行事曆」連結：**任何拿到連結的人都看得到這個行事曆**。介意的話不要用，
或另外建一個只放要顯示在裝置上的行程的行事曆，只公開那一個。

- **iPhone / iPad**：「行事曆」App → 下方「行事曆」→ 行事曆旁的資訊按鈕 ⓘ → 打開「公開行事曆」→
  「分享連結…」→「拷貝」。
- **iCloud.com**：開 <https://www.icloud.com/calendar/> → 左側行事曆名稱旁的分享按鈕 → 勾選「公開行事曆」→
  「拷貝連結」。

連結以 `webcal://` 開頭，直接貼上即可，紙彩會自動改用 `https://` 下載。
不想再公開時，把「公開行事曆」關掉，連結就會失效。

### Outlook.com / Microsoft 365

1. 在 Outlook 網頁版（<https://outlook.live.com/> 或公司的 Outlook 網頁版）→ 右上角齒輪「設定」→
   「行事曆」→「共用行事曆」。
2. 在「發佈行事曆」選要放上裝置的行事曆，權限選「可以檢視所有詳細資料」→「發佈」。
3. 複製 **ICS** 連結（不是 HTML 連結）。

公司或學校帳號若沒有「發佈行事曆」，是管理員沒有開放；只能請管理員開放，或改用個人帳號。
不想再分享時，回到同一個地方按「取消發佈」，連結就會失效。

### 其他

- **Fastmail**：設定 → Calendars → Edit & share → Publish →「Full event details」。
- **Zoho Calendar**：行事曆設定 → Sharing and permissions → Private URL → iCal。
- **Proton Calendar**（付費方案）：設定 → 行事曆 → Share with anyone → Full view 連結。
  Proton 表示更新可能要幾個小時。
- **台灣國定假日**（公開）：
  `https://calendar.google.com/calendar/ical/zh-tw.taiwan%23holiday%40group.v.calendar.google.com/public/basic.ics`
  （由 Google 提供，偶有錯誤，也不含補班日。）

## 二、加入紙彩

1. 按「**行事曆來源…**」→「**新增…**」。
2. 「名稱」會顯示在頁面上（例如「個人」「學校」）；把網址貼到「iCal 網址」（輸入時會以圓點隱藏）；
   「顏色」可以自己選，或留「自動」。「帳號」「密碼 / App 密碼」只有需要登入的來源（例如 Nextcloud）才要填。
3. 按「**檢查並儲存**」。紙彩會先下載一次，確定是行事曆才存起來，並告訴你近期有幾個行程、幾項待辦。

可以加很多個來源（例如個人、學校、家人），每個來源一種顏色。網址被重設時，選那個來源按「**編輯…**」貼上新網址
（留空的欄位不會改變）；「**刪除**」會連同網址一起從這台電腦刪除。

同步時，只要有任何一個來源讀不到，這次就整個不推送（以免頁面少了一本行事曆卻看不出來），
並告訴你是哪一個來源。

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
可以當作行事曆來源加入，但它們會出現在行程的頁面（例如本日＋月曆、本日行程＋一週行程），不在待辦清單頁。

## 四、更新時機

- **立即同步**：按「**立即同步**」，馬上讀取行事曆並更新裝置上的行事曆頁（留言頁、牌卡頁和照片頁不會被動到）。
- **每天定時**：按「**每日排程…**」，填時間（24 小時制，多個時間用逗號分隔；例如早上一次、下午一次），
  按「**啟用／更新排程**」。沒有預設時間：在你自己選時間並啟用之前，排程是關閉的（視窗顯示「目前：未啟用」）。啟用後會在 Windows「工作排程器」建立工作 `Paperhue Sync`：
  - 電腦需要開機，而且你登入了 Windows（同步要用你的藍牙配對與認證管理員裡的網址）。
  - 關機或睡眠時錯過的時間，會在下次開機後補做；剛開機時網路或藍牙還沒好，會隔 2 分鐘再試，最多 3 次。
  - 排程會記住 Paperhue.exe 的位置。之後若把 Paperhue.exe 移到別的資料夾，請再開「每日排程…」按一次
    「啟用／更新排程」。
  - 內容沒變的頁面，裝置會自己略過，不會重刷畫面。頁面上的「更新於」只寫日期，
    所以同一天內只有行程開始或結束、或資料真的變了，才會重畫。
  - 每次的結果（時間、哪幾頁更新了、幾個行程、幾項待辦——不含任何標題）記在
    `%APPDATA%\ulani-epaper\sync-log.jsonl`，紙彩上方會顯示「上次同步」。
  - 停用：「每日排程…」→「**停用排程**」。

## 常見問題

| 狀況 | 原因與處理 |
|---|---|
| HTTP 400 或 404 | 網址被重設或刪除。到原服務複製新網址，用「編輯…」貼上。 |
| HTTP 401 | 需要帳號密碼，或密碼錯了（Nextcloud 請用應用程式密碼）。 |
| 「收到的不是 iCalendar 資料」 | 貼成了網頁網址或公開網址；請用「iCal / ICS」網址。 |
| 學校或公司帳號找不到「私密網址」或「發佈行事曆」 | 管理員關閉了；請管理員開放，或改用個人帳號。 |
| 剛改的行程沒出現 | 服務端的網址還沒更新（Google、Proton 可能延遲）；稍後再同步。 |
| 行程標題的表情符號不見了 | 頁面字型（思源黑體）沒有表情符號，會略過；整個標題都是表情符號時顯示「（無法顯示的標題）」。 |
| 推送照片時「找不到裝置或連不上」，剛好是排程時間 | 裝置一次只能有一個連線：排程同步正在傳送。稍等再推；反過來排程遇到你正在推送，會在 2 分鐘後自動重試。 |

## 命令列（開發者）

安裝 Python 套件 `ulani-epaper[calendar]` 的開發者，也可以用 `ulani` 命令列設定同一份來源與排程：

```
ulani feeds add 個人              # 會請你貼上網址（不顯示、不會留在指令歷史）
ulani feeds add 家務 --user 帳號    # 需要帳號密碼的來源（例如 Nextcloud），會再問密碼
ulani feeds                      # 列出來源（只顯示主機）
ulani feeds test                 # 立刻下載每個來源，看內容是否正常
ulani feeds edit 個人 --url        # 網址重設後換新網址
ulani feeds remove 個人            # 同時從認證管理員刪除網址
ulani sync                       # 立即同步
ulani schedule install --times 06:00 12:00 18:00
ulani schedule remove
```

---

## English summary

Any page of the device can show a Today + month, Today + week, To-do, Day or Month page (set the
page's **Show** menu) from your own **iCal (.ics) addresses**: no third-party API, no cloud project, no sign-in.
Paperhue only reads them. A private address works like a password: paste it only into Paperhue,
which keeps it in the Windows Credential Manager and only ever shows its host. Nothing fetched
(events, to-dos) is stored on disk. The pages drawn on the device are in Chinese for now.

Getting the address:

- **Google Calendar** (on a computer, at calendar.google.com): Settings → Settings for my
  calendars → the calendar → Integrate calendar → "Secret address in iCal format". One per
  calendar. Not the public address. Reset it there if it leaks (then paste the new one with
  **Edit…**). Workspace admins can hide it. Invitations you declined are left out.
- **Apple iCloud** has only public links (anyone with the link can see the calendar): on an
  iPhone, Calendar → Calendars → ⓘ next to the calendar → Public Calendar → Share Link; or at
  icloud.com/calendar, the share button next to the calendar → Public Calendar → Copy Link. The
  `webcal://` link can be pasted as is.
- **Outlook.com / Microsoft 365** (Outlook on the web): Settings → Calendar → Shared calendars →
  Publish a calendar → the calendar, "Can view all details" → Publish → copy the ICS link.
- Fastmail, Zoho and Proton have private links too.

In Paperhue: **Calendar sources…** (行事曆來源…) → **Add…** (新增…), name, address, colour →
**Check and save** (檢查並儲存). **Sync now** (立即同步) updates the pages now. **Daily schedule…**
(每日排程…) creates the Windows Task Scheduler task "Paperhue Sync" once you enter at least one time
and click **Turn on / update** (啟用／更新排程); until then no scheduled sync is set ("Now: off"), and
**Turn off** (停用排程) removes it. It runs only while the PC is on and you are signed in (missed
times are made up later). Unchanged pages are skipped by the device.

To-dos (VTODO): Nextcloud Tasks (`…/remote.php/dav/calendars/USER/LIST/?export&componentType=VTODO`
with an app password), Radicale, Baïkal (switch it to Basic auth). Google Tasks, Apple Reminders,
Microsoft To Do and Proton offer no iCal/CalDAV access to tasks.
