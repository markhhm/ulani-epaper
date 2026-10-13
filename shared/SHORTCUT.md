# iPhone shortcut "Paperhue-Sync": spec

> 中文摘要：`web/public/shortcuts/Paperhue-Sync.shortcut` 是一個已簽署（任何人可加入）的 iPhone
> 捷徑。它讀取 iPhone 行事曆中今天起 45 天的行程與未完成的提醒事項，組成下面的 JSON，
> 以 base64 放在網址的 `#d=` 之後，透過 `bluefy://open?url=…` 在 Bluefy 開啟 Paperhue 網頁，
> 由網頁畫出頁面並送到裝置。捷徑本身不儲存任何內容；網頁也不得儲存（讀完就清掉網址中的資料）。
> JSON 欄位名稱是固定的，網頁依此讀取。

## Status

| Item | Status | Checked by |
|---|---|---|
| Signed shortcut file | Done; signed on macOS 26.6 (Shortcuts 7.0) with `shortcuts sign --mode anyone` | Signature checked against the embedded certificate, which chains to the system's Apple Root CA - G3; the Shortcuts import code opens it (28 actions); a copy with one byte changed is refused |
| JSON and URL | Done | A test copy run with the macOS Shortcuts frameworks on made-up events (see "Verification") |
| On an iPhone | Not tried yet | The owner |

## 1. What it does

1. Takes all events in all of the iPhone's calendars that overlap the window
   from **today 00:00** (local) to **today 00:00 + 45 days**. Events that
   started earlier today, or earlier but are still going on, are included.
2. Takes all reminders that are not completed, from all lists.
3. Builds the JSON in section 2, base64-encodes it and opens
   `bluefy://open?url=<percent-encoded page URL>` (section 4).

The page then draws the calendar pages and sends them to the device. The
shortcut keeps nothing: no file, no variable that outlives the run.

## 2. JSON (binding)

```json
{"v":1,
 "events":[{"title":"Team meeting","start":"2026-10-13T09:00:00+08:00","end":"2026-10-13T10:00:00+08:00","allDay":false,"calendar":"Work"}],
 "reminders":[{"title":"Pay rent","due":"2026-10-14T00:00:00+08:00"},{"title":"Buy milk","due":null}]}
```

(Shown on three lines here; the shortcut writes one line.)

| Field | Type | Notes |
|---|---|---|
| `v` | number | Always `1`. A page that sees another value should refuse the data. |
| `events` | array | Sorted by start, oldest first. `[]` when there are none. |
| `events[].title` | string | The event title; `""` if it has none. |
| `events[].start`, `events[].end` | string | ISO 8601 instant with offset (section 3). |
| `events[].allDay` | boolean | `true` / `false`. |
| `events[].calendar` | string | The calendar's name as the Calendar app shows it (not unique across accounts). |
| `reminders` | array | Sorted by due date. `[]` when there are none. |
| `reminders[].title` | string | The reminder title. |
| `reminders[].due` | string or `null` | ISO 8601 instant with offset; `null` when the reminder has no due date. |

The text is compact JSON from the system's JSON writer, so:

- key order inside an object is not fixed (`{"allDay":true,"title":…}` is normal);
- `/` may be written as `\/`; quotes, backslashes and new lines in titles are
  escaped; other characters (Chinese, emoji) are plain UTF-8;
- there are no other fields (no location, notes, colour, status).

## 3. Dates as Shortcuts writes them

All dates go through Format Date, style ISO 8601, "Include ISO 8601 Time" on:

- Form `YYYY-MM-DDTHH:MM:SS+HH:MM`, seconds always present, no fractions,
  e.g. `2026-10-13T09:00:00+08:00`. A zero offset is written `Z`
  (`2026-10-13T01:00:00Z`), so the page must accept both.
- The offset is the iPhone's time zone **at that instant** (daylight saving
  is applied per date: in New York, `2026-10-15T21:00:00-04:00` and
  `2026-11-10T12:00:00-05:00`). Events from other time zones arrive already
  converted.
- **All-day events**: `allDay` is `true`, `start` is the first day at
  `00:00:00` local and `end` is the **last day at `23:59:59`** local, i.e.
  inclusive (this is how the system calendar stores them). A one-day event on
  13 October: `start` `2026-10-13T00:00:00+08:00`, `end`
  `2026-10-13T23:59:59+08:00`. To get the agenda model's dates (end
  exclusive): first day = date part of `start`; exclusive end = date part of
  (`end` minus 1 second) + 1 day. That rule also works if `end` ever comes as
  the next day's `00:00:00`.
- **Reminders**: a reminder with a date but no time comes out at `00:00:00`
  local on that date; one with a time at that time. The page cannot tell a
  date-only reminder from one due at midnight; treat `00:00:00` as date-only.
  No due date gives `null`.
- Recurring events arrive as separate occurrences; there is no recurrence
  information.

## 4. URL

```
bluefy://open?url=<percent-encoded page URL>
page URL: https://markhhm.github.io/ulani-epaper/?sync=1#d=<base64>
```

- `<base64>`: the UTF-8 bytes of the JSON text, standard base64 alphabet
  (`A–Z a–z 0–9 + /`), `=` padding, no line breaks.
- Shortcuts' URL Encode turns `?`, `=`, `#` into `%3F`, `%3D`, `%23` and leaves
  letters, digits and `: / + - .` as they are. So inside the `url=` value the
  base64 `+` is not encoded. Bluefy decodes the value back to the page URL;
  if anything on the way treats `+` as a space, the page must turn spaces back
  into `+` before decoding (harmless otherwise).
- `?sync=1` tells the page it was opened by the shortcut. The data sits in the
  fragment (`#d=`), which the browser never sends to the server.
- Size: about 170–250 URL characters per event (more for long titles) and
  70–100 per reminder; two events and two reminders give about 600
  characters, 100 events about 20 KB. Neither iOS nor Bluefy documents a
  limit at these sizes; if a very full calendar ever fails to open, shorten
  the window (the 45 in action 3).
- Bluefy may keep the opened URL, data included, in its own history; the page
  cannot prevent that.

Reading it on the page (reference):

```js
const m = /^#d=(.+)$/.exec(location.hash);
if (new URLSearchParams(location.search).get('sync') === '1' && m) {
  const b64 = decodeURIComponent(m[1]).replace(/ /g, '+');
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const data = JSON.parse(new TextDecoder().decode(bytes)); // check data.v === 1
  history.replaceState(null, '', location.pathname); // drop ?sync=1#d=… from the address bar
  // draw and push; never store `data` (no localStorage, IndexedDB, cache or logs)
}
```

## 5. The actions, in order

Identifiers are the plist `WFWorkflowActionIdentifier`s.

| # | Action | Settings |
|---|---|---|
| 1 | Comment (`is.workflow.actions.comment`) | Short zh-TW / English description of what the shortcut does. |
| 2 | Adjust Date (`is.workflow.actions.adjustdate`) | Get Start of Day of Current Date → "Adjusted Date" (window start). |
| 3 | Adjust Date | Add **45 days** to action 2 → window end. |
| 4 | Find Calendar Events (`is.workflow.actions.filter.calendarevents`) | All calendars; **all** of: End Date is after (action 2), Start Date is before (action 3); sort by Start Date, Oldest First; no limit. |
| 5 | Repeat with Each (`is.workflow.actions.repeat.each`) | Calendar Events (action 4). |
| 6 | Format Date (`is.workflow.actions.format.date`) | Repeat Item → Start Date; ISO 8601; Include ISO 8601 Time on. |
| 7 | Format Date | Repeat Item → End Date; same settings. |
| 8 | Dictionary (`is.workflow.actions.dictionary`) | `title` (Text) Repeat Item → Title; `start` (Text) action 6; `end` (Text) action 7; `allDay` (Boolean) Repeat Item → Is All Day; `calendar` (Text) Repeat Item → Calendar. |
| 9 | End Repeat | → Repeat Results (one dictionary per event). |
| 10 | Combine Text (`is.workflow.actions.text.combine`) | Repeat Results, separator Custom `,` (gives `{…},{…}`; empty when no events). |
| 11 | Find Reminders (`is.workflow.actions.filter.reminders`) | Is Completed is false; sort by Due Date, Oldest First; no limit. |
| 12 | Repeat with Each | Reminders (action 11). |
| 13 | If (`is.workflow.actions.conditional`) | Repeat Item → Due Date has any value. |
| 14 | Format Date | Repeat Item → Due Date; ISO 8601; Include ISO 8601 Time on. |
| 15 | Dictionary | `title` (Text) Repeat Item → Title; `due` (Text) action 14. |
| 16 | Otherwise | |
| 17 | Text (`is.workflow.actions.gettext`) | `{"due":null}` |
| 18 | Get Dictionary from Input (`is.workflow.actions.detect.dictionary`) | Action 17 (the Dictionary action has no null type; this keeps a real `null`). |
| 19 | Set Dictionary Value (`is.workflow.actions.setvalueforkey`) | Key `title`, value Repeat Item → Title, in action 18. |
| 20 | End If | |
| 21 | End Repeat | → Repeat Results (one dictionary per reminder). |
| 22 | Combine Text | Repeat Results, separator Custom `,`. |
| 23 | Text | `{"v":1,"events":[`(action 10)`],"reminders":[`(action 22)`]}` |
| 24 | Base64 Encode (`is.workflow.actions.base64encode`) | Encode; Line Breaks **None** (the default, every 76 characters, would break the URL). |
| 25 | URL (`is.workflow.actions.url`) | `https://markhhm.github.io/ulani-epaper/?sync=1#d=`(action 24) |
| 26 | URL Encode (`is.workflow.actions.urlencode`) | Encode action 25. |
| 27 | URL | `bluefy://open?url=`(action 26) |
| 28 | Open URLs (`is.workflow.actions.openurl`) | Action 27. |

Building the arrays with Combine Text instead of putting Repeat Results into a
Dictionary keeps `[]`, one item and many items all as JSON arrays.

Plist notes for whoever edits the file by hand: content filters are
`WFContentPredicateTableTemplate` rows `{Property, Operator, Values}` with
operators 0 "is before / less than", 2 "is after / greater than", 4 "is",
5 "is not", 1000 "is in the next", 1001 "is in the last", 1002 "is today",
1003 "is between"; date values go in `Values.Date` (a variable is a
`WFTextTokenAttachment`), booleans in `Values.Bool`. Calendar Events searches
the calendar between the largest "after" date and the smallest "before" date,
so the search needs both. Dictionary rows use `WFItemType` 0 for text and 4
for boolean; If uses `WFCondition` 100 for "has any value".

## 6. Install on an iPhone

1. Install **Bluefy** from the App Store (the page needs Web Bluetooth).
2. In Safari, open
   `https://markhhm.github.io/ulani-epaper/shortcuts/Paperhue-Sync.shortcut`
   (once the web app links to it, tap the link there). Safari hands the file
   to Shortcuts; if it only downloads it, open Files → Downloads and tap
   `Paperhue-Sync.shortcut`.
3. Tap **Add Shortcut**. The name comes from the file name, `Paperhue-Sync`,
   which is the name the web app runs: keep it (if it was renamed:
   long-press → Rename).
4. Run it once by hand. When it asks for **Calendars**, **Reminders** and to
   open Bluefy, choose Always Allow so later runs do not ask again.
5. Optional: add it to the Home Screen, or run it from an automation. The
   device push still happens in Bluefy, so the iPhone must be unlocked and
   near the device.

## 7. Limits and upkeep

- Declined invitations and cancelled events are included (the system calendar
  keeps them and the shortcut does not filter by status); the iCal path in
  `AGENDA.md` drops declined invitations.
- All calendars are read, including subscribed, holiday and birthday
  calendars.
- The signing certificate in the file is valid until 2027-11-04, and an
  iPhone may refuse to add the file after that. Before then, sign it again on
  a Mac: `shortcuts sign --mode anyone --input <file> --output
  Paperhue-Sync.shortcut` (it accepts an already signed file), or edit the
  shortcut in the Shortcuts app and export it for "Anyone".

## Verification

Done on a Mac (macOS 26.6, Shortcuts 7.0); no Bluetooth, no real calendar or
reminder data was read:

- `plutil -lint` passes on the unsigned plist; the signed file's payload is
  identical to it.
- A test copy with three changes was run with the system's Shortcuts
  frameworks: events came from the shortcut's input (made-up events, including
  one before and one after the window), reminders from a fixed list (one with
  a due date, one without, a title with quotes, `/` and a new line), and the
  last action output "JSON, new line, bluefy URL" instead of opening it.
  Checked: only the two events in the window are kept; the field names and
  types above; `[]` for no events; a multi-day all-day event ends at
  `23:59:59` of its last day; `null` for no due date; offsets `+08:00`
  (Taipei), `-04:00` / `-05:00` (New York across the daylight saving change)
  and `Z` (UTC); the URL decodes back to exactly the same JSON.
- Not checked on a Mac: Find Calendar Events and Find Reminders against a real
  library, and the iPhone import, permission prompts and Bluefy hand-off.
