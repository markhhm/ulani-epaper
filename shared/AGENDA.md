# Calendar and to-do pages: spec for the iOS + macOS app

> 中文摘要：Windows 版可以把使用者自己的 iCal（.ics）行事曆網址畫成「月曆／一週行程／
> 待辦清單」頁面推到裝置，**不依賴任何第三方 API 或雲端專案**。這份文件是 Apple 版的
> 規格：Apple 版要做同樣的功能——每一頁可選照片／月曆／一週行程／待辦清單，
> 管理 iCal 來源（網址存在 Keychain），按「立即同步」下載、解析、畫出與 Python 版相同的
> 頁面、推送。**行事曆內容不得存到 iPhone／Mac 上**（只在記憶體中）。iCal 解析與週期展開請在
> UlaniKit 內自己實作（不用 EventKit、不加外部套件），用 Python 產生的測試向量驗證。
> 每日定時同步由裝置旁的 Windows 電腦負責，Apple 版做手動同步。

## Status

| Item | Status | Checked by |
|---|---|---|
| Python reference: data model, iCal parser, feeds, layouts, sync, schedule, CLI, Windows app | Done (Paperhue 0.3.0); verified on a real device with two real Google secret addresses (2026-10-12) | `python/tests/test_agenda.py`, `test_ical.py`, `test_feeds.py`, `test_layouts.py`, `test_sync.py`, ... |
| Swift port | Not started | - |

## 1. Goal

Each of the four pages shows a **photo**, a **month calendar**, a **week
agenda** or a **to-do list** (default: 1 month, 2 agenda, 3 to-do, 4 photo).
Calendar pages are drawn from the owner's **calendar sources**: iCal (.ics /
webcal) addresses such as Google Calendar's "secret address in iCal format",
an Outlook or iCloud published calendar, or a Nextcloud export link with an
app password. They are pushed with the existing UlaniKit push (one
connection, the page on screen last, unchanged pages skipped by the
device's probe).

The Apple app adds: a page-kind picker per page, a "行事曆來源" list (add
with a masked address field and a check download, edit name/colour/address,
remove), "立即同步" (fetch, draw, show the drawings, push) and the last
sync's outcome. Mirror `python/src/ulani_epaper/gui.py` (`FeedsDialog`, `FeedForm`).

**Who syncs when:** the Windows PC next to the device owns the daily
schedule (Task Scheduler). iOS cannot run timed BLE pushes reliably in the
background, so the Apple apps sync on demand. If both are used, keep the
same page assignment on both or they will overwrite each other's pages.

## 2. Owner's rules (do not change without asking)

1. **No third-party dependency**: no Google (or other) API, no OAuth client,
   no cloud project. Only the addresses the user pastes.
2. **Nothing from the calendar is stored on the iPhone or Mac**: no cache, no
   drawn pages on disk, no per-page hashes, no titles in logs. Fetch, draw,
   push, drop. Only the addresses (Keychain) and the settings (page kinds,
   feed names and colours) are kept.
3. **Apple look** (section 6): white canvas, bold headline, red for today,
   hairlines, round check circles, calendar-colour markers.
4. A source address is a password: never show it after it is saved (show
   only the host), never log it, never put it in an error message.

## 3. Data model (port `agenda.py`)

```
Event { title, start, end, allDay, calendar, location, color }
  allDay:  start/end are dates; end is EXCLUSIVE (iCalendar's convention)
  timed:   start/end are instants with an offset
  color:   "#rrggbb" of the feed, "" = none
Task  { title, due?: date, listName, notes }
AgendaData { events, tasks, fetchedAt? }
```

- `eventsOn(day, tz)`: events touching that local day (`start < dayEnd &&
  end > dayStart`; a zero-length event shows on the day it happens), sorted
  all-day first, then by start, then title. Events crossing midnight appear
  on both days.
- `sortedTasks()`: tasks with a due date by date, then those without; ties
  by title.
- Time zone: the phone's or Mac's current zone (`TimeZone.current`), DST-aware for
  every instant (Python: `agenda.LOCAL`).
- JSON (fixtures only): `shared/layouts/agenda/{sample,empty,busy,midday}.json` are
  `AgendaData` JSON plus `"today"` and `"utc_offset"`. Dates are
  `YYYY-MM-DD`; instants are ISO 8601 with offset. Missing optional fields
  default to `""` / null. Your parser must read all four files.

## 4. Calendar sources (port `feeds.py` and `ical.py`)

### 4.1 Settings and secrets

- Settings: `feeds = [{id, name, color}]` in display order; `color` is a panel
  colour name (red, orange, yellow, green, blue, black), `#rrggbb`, or ""
  (automatic). Ids are 8 random hex characters.
- The address (+ optional user name and password for addresses that need
  HTTP Basic auth) lives in the **Keychain**: `kSecClassGenericPassword`,
  service `<bundle id>.ical-feed`, account = feed id, value = JSON
  `{"url", "user", "password"}`. Use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (not synced to iCloud;
  syncing would be the owner's decision) and `kSecUseDataProtectionKeychain`.
  The `ulani-swift` command line tool has no provisioning profile (Apple
  TN3137); let it take the address from stdin or an environment variable.
- Automatic colours (`feeds.colours`): feeds without a colour get, in order,
  the first of blue, red, green, orange, yellow, black not used by a feed
  that has one.

### 4.2 Fetching (port `feeds.download`, `feeds.fetch`, `feeds.window`)

- `normalize_url`: trim; `webcal://` and `webcals://` become `https://`;
  only http/https with a host are accepted.
- One `URLSession(configuration: .ephemeral)`, `urlCache = nil`, no cookies.
  GET with `User-Agent: Paperhue/<version>` (any identifying value is
  fine), `Accept: text/calendar, */*`, Basic auth when a user/password is
  stored. 30 s timeout. Refuse bodies over 20 MB. Parse from memory; never
  write the body to a file.
- Redirects: follow them, but refuse https -> http, and do not send the
  Authorization header to the redirect target
  (`urlSession(_:task:willPerformHTTPRedirection:...)`).
- Declined invitations: Google's feed keeps them; the only sign is the
  owner's own `ATTENDEE;PARTSTAT=DECLINED` line. `feeds.owner(url)` takes the
  owner's e-mail from a Google secret address
  (`calendar.google.com/calendar/ical/<e-mail>/private-…`, not for
  `…@group.calendar.google.com` ids) and `ical.parse(owner=…)` leaves those
  events out, judging each moved occurrence on its own.
  (`python/tests/test_ical.py::DECLINED` is the case to port.)
- Errors without the address: `HTTP 400（網址無效，或已被重設）` (Google, after a
  reset), `HTTP 404（找不到：網址可能已重設或刪除）`,
  `HTTP 401（需要帳號密碼，或密碼不對）`, `HTTP 403（沒有權限）`,
  `無法連線到 <host>（<error type>）`, `收到的不是 iCalendar 資料（網址可能不對，或需要登入）`.
  Prefix the feed name: `個人：HTTP 404（…）`. Redact `URLError.failingURL`.
- Window (`window(today)`): from the 1st of today's month minus 7 days to
  `max(1st of next month + 14 days, today + 31 days)`, local midnights,
  end exclusive.
- `fetch`: every feed in order; **one failing feed fails the whole sync**
  (the pages are not pushed), naming the feed. No feeds at all ->
  `尚未設定行事曆來源` (not retried).
- Adding a source downloads it once (`probe`) and saves it only if it parses;
  the message shows `近期 N 個行程、M 項待辦`.

### 4.3 Parsing and recurrence (port `ical.py` exactly)

The research for this port found no maintained, permissively licensed Swift
package that expands RRULE correctly on iOS 17 / macOS 14 (icalendar-kit
needs iOS 18 and ignores BYxxx/EXDATE/RDATE/RECURRENCE-ID; the others are
parse-only, unlicensed or archived; `Calendar.RecurrenceRule` needs iOS 18),
and EventKit cannot add a subscription without the user confirming, keeps
the events and the address in the OS, and ignores to-dos. So: **a small
parser and expander inside UlaniKit, no external dependencies**, checked
against the Python vectors (4.4).

- Parser: line unfolding (CRLF or LF + space/tab), properties with
  parameters, TEXT unescaping (`\n`, `\,`, `\;`, `\\`), VCALENDAR, VEVENT,
  VTODO, VTIMEZONE; DATE, DATE-TIME (UTC `Z`, `TZID=`, floating) and
  DURATION values. Not a calendar (no VCALENDAR) -> error.
- Time zones: `TZID` as an IANA name; Windows names (`Taipei Standard Time`)
  through CLDR's windowsZones mapping; otherwise the feed's own VTIMEZONE
  (STANDARD/DAYLIGHT with RRULE). Floating times use `X-WR-TIMEZONE` if it
  is a valid zone, else the page's zone.
- Duration: DTEND - DTSTART, else DURATION, else 1 day (all-day) / 0 (timed).
  All-day events last at least one day.
- Expansion (window [start, end)): RRULE (FREQ, INTERVAL, COUNT, UNTIL,
  BYDAY with ordinals, BYMONTHDAY, BYMONTH, BYYEARDAY, BYWEEKNO, BYSETPOS,
  WKST), RDATE, EXDATE (several lines, comma lists). UNTIL as a date with a
  timed DTSTART means "through that day" (23:59:59 in the event's zone);
  UNTIL in UTC with a local DTSTART is compared as an instant. An
  occurrence is kept if `start < windowEnd && start + duration >
  windowStart` (zero-length: `windowStart <= start < windowEnd`).
- Overrides: VEVENTs with `RECURRENCE-ID` replace the master's occurrence
  with the same original start (compare instants; dates for all-day), even
  when the override moves it into or out of the window. `STATUS:CANCELLED`
  on an override removes that occurrence; on a master, the whole series.
- Limits: stop a series after 500 occurrences inside the window; give up on
  a series (skip it, count it as skipped) after 200,000 rule steps from
  DTSTART. A series that fails to parse is skipped, not fatal.
- To-dos: every VTODO except `STATUS:COMPLETED`/`CANCELLED`, a `COMPLETED`
  property, `PERCENT-COMPLETE:100` or an empty SUMMARY. `due` = the DUE date
  (a DATE-TIME converted to the page's zone first); `notes` = first non-empty
  line of DESCRIPTION. Recurring to-dos are shown once, as they are. To-dos
  ignore the window.
- Names: an event's `calendar` and a task's `listName` are the feed's name
  (`X-WR-CALNAME` only suggests a name when adding a source).

### 4.4 Vectors

[`shared/vectors/ical-vectors.json`](vectors/ical-vectors.json) (regenerate from the repo root with
`python -m ulani_epaper.ical shared/vectors/ical shared/vectors/ical-vectors.json`)
gives, for each of `shared/vectors/ical/{google,outlook,todos}.ics` and for
October and November 2026 (UTC+8), the expected events (title, start, end,
allDay, location; timed values written in +08:00) and to-dos. They cover a
weekly series with EXDATE, overrides that move, move in and cancel, a yearly
all-day event since 2000, UTC, a midnight crossing, a cancelled event,
floating time, no SUMMARY, DURATION with COUNT, no DTEND, a Windows TZID, a
custom DST VTIMEZONE with a date UNTIL across the DST change, and to-dos
with date and date-time DUE. **UlaniKit must reproduce every case.**
Extra edge cases worth your own tests: BYSETPOS=-1, nonexistent and
repeated local times on DST days, EXDATE as a DATE against DATE-TIME
occurrences.

## 5. Text and colour rules

- **Fonts**: bundle `python/src/ulani_epaper/fonts/NotoSansCJKtc-{Regular,Bold}-subset.otf`
  (SIL OFL, `OFL.txt` must ship too). Do not use system fonts: glyph shapes
  and metrics must match the Python renders. The subset keeps only the
  Traditional Chinese glyph forms (no Japanese, Korean or Simplified `locl`
  forms), so Simplified Chinese, kana and Hangul draw the same whatever
  language Core Text assumes.
- **Missing glyphs** (`fonts.clean`): turn whitespace and control characters
  into spaces, drop every character the bundled font has no glyph for
  (`CTFontGetGlyphsForCharacters` returns false; emoji, ZWJ, variation
  selectors), fold runs of spaces, trim.
- **Feed colour -> panel colour** (`image.accent`): parse `#rrggbb`
  (anything else -> the default, black); HSV with s < 0.2 or v < 0.25 ->
  black; otherwise by hue in degrees: < 10 red, < 40 orange, < 75 yellow,
  < 165 green, < 330 blue, else red. `python/tests/test_image.py` lists 27 colours
  with the expected result: port them as a table test.
- **No anti-aliasing anywhere** (`CGContext.setShouldAntialias(false)`,
  `setAllowsFontSmoothing(false)`), only the 7 palette colours; encode with
  dithering off. A stray in-between colour is a bug (Python raises).

## 6. Layouts

The design ("Apple widgets") was chosen from four candidates by judges who
looked at the renders (Apple fidelity, legibility at 1-2 m, robustness).

- **Spec:** [`shared/LAYOUTS.md`](LAYOUTS.md) has every box, font size
  and weight, colour, label format, truncation, overflow and empty-state
  rule. When the spec and `python/src/ulani_epaper/layouts.py` disagree, the code
  is right; tell this side.
- **Golden renders:** `shared/layouts/agenda/golden/{month,agenda,todo}_{sample,empty,busy,midday}.png`
  and `.txt` (every string drawn, in order: compare these exactly, the
  pixels with a tolerance), from the four fixtures (regenerate from the repo root with
  `python -m ulani_epaper.layouts shared/layouts/agenda shared/layouts/agenda/golden`).
  `midday` is the sample synced at 13:30 (an upcoming event, ended ones).
- Rules worth noting (all in the spec): the sync stamp is the date only
  ("更新於 10/12"), so a page is the same image between two syncs on the
  same day unless an event started or ended; closing punctuation never
  starts a wrapped line (the previous character moves down with it); an
  emoji-only title shows `（無法顯示的標題）`, an empty one `（無標題）`.
- **"Now"** is `fetchedAt` when it falls on today, else today's midnight.
  Never read the clock in the renderer, so renders stay deterministic.
- Port the drawing primitives as listed in the spec: baseline-anchored
  text, rect, rounded bar, filled circle, ring, line, dotted hairline
  (every other pixel). With anti-aliasing off, CoreGraphics rasterises
  the bundled font slightly differently from FreeType, so re-check the
  16-18 px glyphs (四, 週) and the baselines on your own renders.
- Same text rules as Python: titles through `clean`, empty titles become
  `（無標題）`, ellipsis truncation never mid Latin word, CJK never below
  18 px (16 px only for the sync time and digit-only end times).

## 7. Tests

- Parse the four agenda fixtures; `eventsOn` / `sortedTasks` cases from
  `python/tests/test_agenda.py`.
- iCal: every case of `shared/vectors/ical-vectors.json` (4.4), plus the
  inline cases of `python/tests/test_ical.py` (broken RRULE skipped, not a
  calendar, runaway rule skipped, dense series capped, daily since 2010).
- Feeds: `python/tests/test_feeds.py` (URL normalising, errors never containing the
  address, one failing feed fails the fetch, automatic colours) with a fake
  URL loader.
- Layouts: render every fixture and compare with the golden PNGs (section
  6). FreeType and CoreText rasterise differently, so compare per region
  with a tolerance rather than byte for byte, check exact palette use, and
  compare the drawn strings with the `.txt` goldens exactly.

## 8. Hardware verification

1. Add the owner's sources on the iPhone, sync with pages 1-3 as calendar
   pages: the drawings match the Windows app's for the same data and day.
2. Sync again with nothing changed: every page reported unchanged, no
   panel refresh.
3. Change one event in the calendar, wait until its iCal address shows it
   (Google's secret address can lag), sync: only the affected page(s) upload.
