# Paperhue calendar pages: layout spec ("Apple widgets", final)

Reference implementation: [`python/src/ulani_epaper/layouts.py`](../python/src/ulani_epaper/layouts.py).
Golden renders of the fixtures in [`shared/layouts/agenda/`](layouts/agenda/) (sample, empty,
busy, and midday: the sample synced at 13:30, with ended and upcoming events):
[`shared/layouts/agenda/golden/`](layouts/agenda/golden/), a PNG plus a `.txt` with every drawn
string in drawing order, one per line (regenerate both from the repo root with
`python -m ulani_epaper.layouts shared/layouts/agenda shared/layouts/agenda/golden`).
Compare pixels with a tolerance, the strings exactly.
Checks: `python/tests/test_layouts.py`. This document is precise enough to reproduce the pages in
Swift / CoreGraphics. When this text and the code disagree, the code is right; please report
the difference.

## 1. Global

| Item | Value |
|---|---|
| Canvas | 800 x 480 px, RGB, white background |
| Palette | black (0,0,0), white (255,255,255), green (0,255,0), blue (0,0,255), red (255,0,0), yellow (255,255,0), orange (255,125,0). No other colour, no anti-aliasing |
| Margins | `MARGIN = 28` left and right. `BOTTOM = 462`: no ink below y = 462 |
| Header baseline | `HEADER_BASE = 56` on every page (weekday / title / sync stamp / to-do count) |
| Font | Bundled Noto Sans CJK TC subset (Traditional Chinese glyph forms), Regular and Bold only, 1-bit rendering (`fontmode = "1"`) |
| Time format | 24-hour, zero-padded `HH:MM` ("09:00", "23:00"), everywhere |
| Week | Starts on Sunday: 日 一 二 三 四 五 六 |
| Clock | Never read. "now" is derived from `data.fetched_at` (see 2.4) |

### 1.1 Type scale

| Name | Size / weight | Used for |
|---|---|---|
| SIZE_SYNC | 16 Regular | "更新於 10/12" only |
| SIZE_END_TIME | 16 Regular | end time under the start time (digits only) |
| SIZE_NOTE | 18 Regular / Bold | times, locations, "還有 N 項", section labels (bold), weekday labels |
| SIZE_TITLE | 20 Regular / Bold | event titles in rows |
| others | see each page | |

Rule: CJK text is never set below 18 px. At 16-17 px Regular, 四 rasterises nearly solid, so
16 px is used only for strings without complex CJK ("更新於 10/12", "17:00", "10/20").
Bold CJK smaller than 18 px is never used. No yellow or green text anywhere: calendar colours
appear only as bars, dots and the yellow keyline.

### 1.2 Text drawing contract

* All text is drawn with a **baseline anchor**: `ls` (left, baseline), `rs` (right,
  baseline) or `ms` (horizontal centre of the advance width, baseline). Every y below is a
  baseline unless it says "top".
* Every string goes through `fonts.clean()` (NFC, drops emoji and missing glyphs, folds
  whitespace) inside the text primitive, so no call site can draw raw emoji. Titles
  (`_title`): an empty or blank title is drawn as `（無標題）`; a title that is not empty but
  has only characters the font lacks (e.g. "🎂🎉") as `（無法顯示的標題）`. Locations and list
  names are cleaned first and only then tested for emptiness, so an emoji-only location
  takes no space.
* **Truncation** `_fit(text, font, maxw)`: if `advance(text) <= maxw` draw as is; otherwise
  binary-search the longest prefix p with `advance(p.rstrip() + "…") <= maxw`. If the cut
  falls between two Latin/digit characters, back off to the previous space (no "Quart…"). If
  nothing fits, draw "…" alone (or nothing if even "…" does not fit).
* **Wrap** (hero title only) `_wrap(text, font, width, 2)`: tokens are whole Latin words
  `[0-9A-Za-zÀ-ɏ'’.,:;!?&+#@%/\-]+`, whitespace runs, or single characters (CJK). Greedy
  fill, but a token from `，。、：；！？）」』》〉】,.:;!?)` never starts a line: when it would
  not fit at the end of a line, the line's last token moves down with it
  ("讀完《原子習慣》" at 7 characters per line -> "讀完《原子習" / "慣》"). A Latin word wider
  than the line is split into characters. If more than 2 lines result, line 2 is the
  remaining text truncated with `_fit`.
* Separator between metadata items: `"·"` (U+00B7) with **no spaces**. The font's middle
  dot is full-width (18 px at 18 px), so it already carries its own spacing.

### 1.3 Drawing primitives (all aliased)

| Primitive | Definition |
|---|---|
| `text(x, y, s, size, bold, fill, anchor, maxw)` | as 1.2; returns the advance width drawn |
| `bar(x, y0, y1, colour, w)` | rounded rect (x, y0)-(x+w-1, y1), radius `w // 2`, fill = colour; **yellow gets a 1 px black outline** |
| `dot(cx, cy, r, colour)` | ellipse bbox (round(cx-r), round(cy-r), round(cx+r)-1, round(cy+r)-1), fill = colour; yellow gets a black outline |
| `disc(cx, cy, r, fill)` | same bbox, filled, no outline |
| `ring(cx, cy, r, colour, width)` | same bbox, outline only, `width` px |
| `rect(x0, y0, x1, y1)` | filled, inclusive corners |
| `line(points, colour, width)` | polyline |
| `hairline_h(x0, x1, y)` | "grey" hairline: black pixels at x = x0, x0+2, x0+4 ... <= x1 |
| `hairline_v(x, y0, y1)` | same, vertical |

Calendar colour: `accent(event.color)` gives one of red, orange, yellow, green, blue, black,
which maps to the palette RGB.

## 2. Shared data rules

### 2.1 Day membership and order
`data.events_on(day, tz)`: all-day first, then by local start, then title. All-day `end` is
exclusive. Timed events crossing midnight appear on both days. A zero-length event appears
only on the day it happens.

### 2.2 Event classes on a given day
* **covers day**: all-day, or a timed event with `start <= 00:00(day)` and `end >= 00:00(day+1)`
  (for example an exactly-24 h or 48 h event on its middle day). These are drawn like all-day
  events ("全天").
* **continuation**: timed, starts before 00:00(day), does not cover the day (so it ends on
  `day`). Drawn as "至HH:MM".
* **timed**: everything else.

`_split_day(events, day, now)` returns (covers-day events, pending timed events, number of
ended timed events). A timed event is **pending** if `end > now`, or if it is zero-length and
`start >= now`. When `now` is None (used for tomorrow), every timed event is pending.

### 2.3 Labels
| Function | Output |
|---|---|
| start label (time column line 1) | "全天" (covers day), "至HH:MM" (continuation, end time, no space), else start "HH:MM" |
| end label (time column line 2, 16 px) | "" for covers-day, continuation and zero-length. "HH:MM" if end <= 00:00(day+1) (midnight shows "00:00"). "HH:MM" if it ends on day+1 at a time-of-day earlier than its start (23:00 over 01:00). Otherwise "M/D" (e.g. "10/13", "12/31") |
| range text (cards, hero) | covers day: "全天", plus "·第 k 天，共 n 天" if it spans several days. Zero-length: "HH:MM". Continuation: "至 HH:MM". Ends the same day: "HH:MM – HH:MM" (en dash with spaces; midnight end is "00:00"). Ends next day: "HH:MM – 隔天 HH:MM". Later: "HH:MM – M月D日 HH:MM" (year prefixed "YYYY年" if a different year). No words relative to the reader's today, so the same text is correct in a "明天" section |
| span note | days spanned: all-day = (end − start) days; timed = local start date … date of (end − 1 µs). If n > 1: "第 k 天，共 n 天" with k = day − first + 1 |
| detail (card line 2) | range text, then "·" + cleaned location if any |
| weekday | long "星期一", short "週一" (`WEEKDAYS = "一二三四五六日"` indexed by Monday=0) |
| month-day | "10月12日"; with year "2027年3月1日" when the year differs from the reference |
| more | "還有 N 項" |

### 2.4 "now" and the sync stamp
* `now` = `fetched_at` converted to tz **if it is tz-aware and falls on `today`**, else
  00:00 of `today`. A missing or naive `fetched_at` gives 00:00.
* Sync stamp (16 Regular, black, right-aligned at x = 772): "更新於 M/D" of the local
  `fetched_at` date, "更新於 YYYY/M/D" if its year differs from `today`'s. **Never the
  time**: two syncs on the same day with nothing starting or ending in between must give
  the same image, so the device skips the page instead of refreshing the panel. A page
  still on screen days later shows its date. Omitted when `fetched_at` is None; a naive
  `fetched_at` is used as is.

### 2.5 Next event
`_next_event(after=today)`: among **all** events whose local start is >= 00:00(today+1),
the minimum by (start, timed after all-day, title). Used by "下一個行程".

## 3. Shared row components (x, y = row top-left, w = available width)

| Component | Height | Geometry |
|---|---|---|
| **All-day line** | 34 | baseline y+22. Dot r=5 centred (x+5, y+14). Title 20 Bold at x+15. One event: title truncated to w−15; then, if it fits entirely, the span note (18 Regular) at title end + 12. Several: item i is dot + 15 px + bold title, items 16 px apart. k = the largest count (>= 1) with Σ item widths + 16·(k−1) + (16 + width("+R")) <= w, where R = n − k (no "+R" term when R = 0). The last drawn title is truncated to fit the remaining room (minus the "+R" reserve). Then "+R" in 18 Regular, 16 px after the last item |
| **Card** (two lines) | 56 | bar w=5 (x, y+4)-(x+4, y+45). Title 20 **Bold** at (x+15, y+20), max w−15. Detail 18 Regular at (x+15, y+44), max w−15 |
| **Line row** (one line) | 28 | start label 18 Regular at (x, y+22). Bar w=4 at x+70, y+5…y+24. Title 20 at (x+82, y+22), **Bold in the left "today" lists, Regular in the six-day list**, max w−82−(more width+12). Optional "還有 N 項" 18 Regular right-aligned at (x+w, y+22) |
| **Note line** | 28 | 18 Regular at (note_x, y+21). note_x = x+15 after cards, x after line rows |
| **Section label** | 36 | 10 px gap, then 18 **Bold** black at (x, y+28): "明天", "下一個行程". ("今天稍後" in 5.2 has no gap: baseline y+18, advance 26) |
| **Next card** | 36 + 56 | Section label "下一個行程", then a card whose line 2 is "明天 HH:MM" or "M月D日 週X HH:MM" (start label rules: "全天" for all-day / covers-day), plus "·location" |

**Timed list** `_timed_list(x, y, w, bottom, events)` (n events, avail = bottom − y):
1. if `n·56 <= avail`: all as cards;
2. else if `n·28 <= avail`: all as line rows;
3. else k = max(0, floor((avail − 28) / 28)) line rows, then a note line "還有 (n−k) 項"
   (own line, at x) if it fits. Nothing is dropped silently.

## 4. Month page (`render_month`)

### 4.1 Boxes
| Box | x, y, w, h |
|---|---|
| Today panel | 28, 0, 262, 462 |
| Month grid | x0 = 326, x1 = 778 (7 columns, cw = 64.571); title row, weekday row, weeks 110…464 |

Column centres `cx_i = 326 + cw·(i + 0.5)`: 358.29, 422.86, 487.43, 552.00, 616.57, 681.14, 745.71.

### 4.2 Today panel
| Element | Spec |
|---|---|
| Weekday | "星期一" 26 Bold **red**, (28, 56) |
| Numeral | today.day, 128 Bold black, (28, 168) |
| List | starts at y = 196, w = 262, bottom = 462 |

Algorithm (y = 196):
1. If today has no events: "今天沒有行程" 22 Bold at (28, y+24); y += 34.
2. Else: all-day line for the covers-day events (if any). If nothing is pending but some
   events ended: "今天沒有其他行程" 22 Bold, y += 34. Timed list of the pending events with
   bottom = 462 − (28 if ended > 0). If ended > 0: note "稍早已結束 N 項".
3. Tomorrow: if tomorrow has events and `y + 10 + 26 + (34 if it has all-day) + (28 if it has
   timed)` <= 462: section label "明天", its all-day line, then the timed list of all of
   tomorrow's timed events (bottom 462). Stop.
4. Else if today had no events: next card ("下一個行程") for `_next_event`; if there is none,
   "近期沒有行程" 18 Regular at (28, y+22) (not "none at all": the data reaches only weeks
   ahead).

### 4.3 Grid
| Element | Spec |
|---|---|
| Title | at x = round(cx_0 − 9) = 349, baseline 56: "2026年" 28 Regular black, immediately followed by "10月" 28 **Bold red** |
| Sync stamp | right-aligned at (772, 56), 16 Regular |
| Weekday labels | 日 一 二 三 四 五 六, 18 Regular, centred (`ms`) on cx_i, baseline 98 |
| Weeks | `calendar.Calendar(firstweekday=Sunday).monthdatescalendar` gives 4, 5 or 6 weeks. Row pitch rh = min(84, 354 / weeks) = 84 / 70.8 / 59. Row r top = 110 + rh·r |
| Numeral | centre cy = top + 22; baseline = cy + 8 (centres the digit box −16…0 of 22 px); 22 Regular black, `ms` on cx_i. Days outside the month are not drawn |
| Today | red disc r=19 at (cx, cy); numeral 22 **Bold white** |
| Dots | see below; centre row dy = round(cy + 28) |

No grid lines, no cell borders.

**Dots per day**: `seq` = accent colour of each of `events_on(d)` in order. distinct = unique
colours in first-appearance order; extra = seq minus one occurrence of each distinct colour.
dots = (distinct + extra)[:4], then stably sorted by distinct index (same colours adjacent).
So each calendar shows first, and repeats show load up to 4. plus = (number of events > 4).
Group width G = 12·n − 2, plus 4 + 9 if plus. gx = round(cx − G/2). Dot j: centre
(gx + 5 + 12·j, dy), r = 5 (10 px). Plus mark (black) at px = gx + G − 9: rect (px, dy−1)-(px+8, dy)
and rect (px+3, dy−5)-(px+4, dy+3).

## 5. Agenda page (`render_agenda`)

Days = today + 0…6. If none of the 7 days has an event, draw the **empty state** (5.4)
instead.

### 5.1 Boxes and header
| Box | x, y, w, h |
|---|---|
| Header | baseline 56: "星期一" 28 Bold **red** at x = 28, then 12 px, then "10月12日" 28 Bold black. If today+6 is in a different year: "2026年12月28日" |
| Sync | (772, 56) right-aligned |
| Left column (today) | 28, 84, 326, to 462 |
| Divider | `hairline_v(380, 84, 462)` |
| Right column (next 6 days) | 404, 84, 368, to 462. Day label column 54 wide; event rows at nx = 458, nw = 314 |

### 5.2 Left column (y = 84)
1. Covers-day events: all-day line; y += 34 + 6.
2. **Hero** = first pending timed event (see 2.2 / 2.4):
   * label "進行中" if start <= now < end else "接下來": 18 Bold **red** at (28, y+18); y += 28; y0 = y;
   * title: wrap to <= 2 lines in 40 Bold, width 326 − 22; each line at (50, y+42); y += 52 per line;
   * range text 26 Regular at (50, y+28), max 304; y += 36;
   * location (cleaned, if any) 20 Regular at (50, y+24), max 304; y += 32;
   * bar w=7, colour = calendar, from (28, y0+10) to (34, y−6), radius 3; y += 14.
3. No hero: "今天沒有行程" (no events today) or "今天沒有其他行程", 30 Bold at (28, y+34);
   y += 56; if ended > 0, note "稍早已結束 N 項" at x = 28. Then, if `_next_event` exists and
   y + 8 + 36 + 56 <= 462: next card at y + 8.
4. **Rest of today** = pending[1:]. If non-empty and y + 26 + 28 + (28 if ended) <= 462:
   label "今天稍後" 18 Bold at (28, y+18), then the timed list from y+26 with bottom
   462 − (28 if ended). Else, if non-empty: note "還有 N 項".
5. If ended > 0 (and not already shown in 3): note "稍早已結束 N 項" (x = 43 after cards,
   28 after line rows) if it fits.

### 5.3 Right column: the next six days
Per day i (days today+1…today+6), rows are either **compact** (line row, 28 px, regular
title) or **full** (50 px):

| Full row | Spec |
|---|---|
| line 1 baseline y+22 | start label 18 Regular at nx; title 20 Regular at nx+82, max 232 |
| line 2 baseline y+44 | end label 16 Regular at nx; location 18 Regular at nx+82 (max 232 − more width) |
| bar | w=4 at nx+70, y+5 … y+44 |
| more | "還有 N 項" 18 Regular right-aligned at (nx+314, y+44) |

Covers-day and continuation rows are always one line (28) even in a full day.

Day block: day number 26 Bold black at (404, y+22). Sub-label 18 Regular at (404, y+44):
"明天" for the first day, "N月" when the day is the 1st of a month, else "週X". A day without
events shows "沒有行程" 18 Regular at (540, y+22). Block height = max(50, Σ row heights) + 6.

**Allocation** (budget = 462 − 84 + 6 = 384):
1. shown_i = min(1, n_i); all days compact.
2. Round-robin over days in date order, adding one compact row to a day while the total
   fits; repeat passes until a full pass adds nothing.
3. everything = all days fully shown. For each day in date order: switch it to full rows if
   that costs no height (for example a single timed event, 50 = label height), or if
   `everything`; keep the switch only if the total still fits.
4. On the last shown row of a truncated day, "還有 (n − shown) 項" is right-aligned on that
   row (line 1 for compact, line 2 for full).

### 5.4 Empty state (whole week empty)
Centred on x = 400 (`ms`): "星期一" 30 Bold red at y 100; day number 128 Bold black at 232;
"2026年10月12日" 22 Regular at 274; `hairline_h(250, 550, 298)`; "今天沒有行程" 30 Bold at 346;
"接下來 6 天也沒有行程" 20 Regular at 380. Sync stamp at (772, 56).

## 6. To-do page (`render_todo`)

### 6.1 Header
| Element | Spec |
|---|---|
| Title | "待辦事項" 32 Bold **blue** at (28, 56) |
| Count | number of open tasks, 44 Bold **blue**, right-aligned at (772, 56) |
| Summary | baseline 86, x = 28: "N 項已逾期" 18 Bold **red**, then "·", then "M 項今天到期" 18 Bold **blue** (each part only if > 0) |
| Sync | 16 Regular right-aligned at (772, 86) |
| List area | y 96 … 462 (366 px). Columns: one full-width column x = 28, w = 744; or two columns x = 28 and 422, w = 350 (gutter 44) |

### 6.2 Task classes and labels
Order: `data.sorted_tasks()` (dated by due date, then undated). Kind: overdue (due < today),
today (due == today), later (due > today), undated.

| Kind | Ring | Second-line segments (two-line rows), joined by "·" |
|---|---|---|
| overdue | red, 2 px | "昨天" (1 day) or "逾期 N 天" **red Bold**; then the date "10月10日" (year added if different) black, if more than 1 day |
| today | **blue**, 2 px | "今天" **blue Bold** |
| later | black | "明天" or "10月15日 週四" ("2027年3月1日 週一" in another year) |
| undated | black | (none) |
| all | | then the cleaned list name and notes, if any |

Titles are always **Regular** (Reminders does not bold titles). Urgency is shown by ring colour
and the coloured label, and overdue and today differ in both colour and wording.
`_parts_line` draws the segments left to right; the segment that does not fit is truncated with
"…" and drawing stops.

### 6.3 Flat list (when it fits)
The first layout that holds all n tasks is used:

| Layout | Columns | Row style | Capacity |
|---|---|---|---|
| 1 | 1 (w 744) | LARGE | 5 |
| 2 | 1 (w 744) | NORMAL | 7 |
| 3 | 2 (w 350) | LARGE | 10 |
| 4 | 2 (w 350) | NORMAL | 14 |

Row styles (y = row top, x = column x, tx = x + 2r + 12):

| Style | ring r | title | detail | pitch | title baseline | detail baseline | ring centre |
|---|---|---|---|---|---|---|---|
| LARGE | 13 | 26 Regular | 20 Regular | 72 | y+30 | y+58 | (x+13, y+30 − round(26·0.38) = y+20) |
| NORMAL | 11 | 22 Regular | 18 Regular | 52 | y+24 | y+46 | (x+11, y+24 − 8 = y+16) |

Title at tx, max x+w−tx. Two columns are balanced: rows = ceil(n / 2), filled top to bottom.
Separator `hairline_h(tx, x+w, y + pitch − 1)` under every row except the last in its column.

### 6.4 Sections (more than 14 tasks)
Sections in order: 逾期 (red), 今天 (blue), 之後 (black), 未排定 (black); empty ones are
skipped. The area is a grid of uniform **44 px slots**, 8 per column (96 … 448), 2 columns,
16 slots in total. A slot holds a header, a task row, or a "還有 N 項" line.

**Flow** for an allocation `shown[s]`: for each section, (a) if the next slot is the last of a
column, insert a blank slot (a header never ends a column); (b) the header; (c) each shown task,
then "還有 (n−shown) 項" if truncated. Whenever a body item would start a new column, the
section header is **repeated** there first (sticky header). An allocation fits if the slot count is
<= 16.

**Allocation**: shown = 1 for every section. Phase 1: round-robin over 逾期 and 今天
(one more row each per pass, kept only if it fits) until no growth. Phase 2: the same over
之後 and 未排定. So overdue and due-today tasks always get space first, and every section
keeps at least one visible row plus its count.

Slot drawing (x = column x, y = slot top, tx = x + 34):
* header: name 20 Bold in the section colour at (x, y+30); count 20 Bold, same colour,
  right-aligned at (x+350, y+30); `hairline_h(x, x+350, y+38)`.
* task: ring r=11, 2 px, at (x+11, y+22) in the kind colour; title 22 Regular at (tx, y+30);
  right label 18, right-aligned at (x+350, y+30), max width 116: overdue "逾期 N 天" / "昨天"
  red Bold; later "明天" / "10月15日" (year if needed) black; today and undated show the list
  name (black). Title max = x + 350 − tx − (label width + 12).
* more: "還有 N 項" 18 Regular at (tx, y+28).

### 6.5 Empty state
Blue ring r=32, 3 px, at (400, 224); check mark polyline (386,225)-(396,235)-(415,214), blue,
4 px; "沒有待辦事項" 30 Bold centred at baseline 304; "全部完成了" 20 Regular centred at 338.
The header (title and count "0") and sync stamp remain.

## 7. Overflow and empty-state summary

| Where | Rule |
|---|---|
| Month today list | cards, then line rows, then line rows + own-line "還有 N 項"; ended events become "稍早已結束 N 項" |
| All-day line | as many as fit + "+N" |
| Month grid | up to 4 dots + "+" when a day has more than 4 events |
| Agenda rest of today | same as the month today list, under "今天稍後" |
| Agenda six days | round-robin rows; "還有 N 項" right-aligned on the day's last row |
| To-do | flat list up to 14; sections with per-section "還有 N 項" beyond that |
| Empty | month: "今天沒有行程" + "下一個行程" card or "近期沒有行程"; agenda (week empty): Calendar-icon date + "今天沒有行程 / 接下來 6 天也沒有行程"; agenda (today empty): "今天沒有行程" + "下一個行程" card; six-day list: "沒有行程" per empty day; to-do: blue check + "沒有待辦事項 / 全部完成了" |

## 8. Verification (python/tests/test_layouts.py)
For every render: size 800x480; colours a subset of the 7; `preview(encode(img, dither=False))`
is byte-identical; rendering twice is byte-identical; every text draw's bbox is inside the canvas,
contains only drawable glyphs, and does not overlap another text bbox by 2 px or more in both
axes; the fixtures match their golden renders. Also covered: 4-, 5- and 6-week months
(February, August), year ends, 200 extra tasks, a 300-character title, an untitled zero-length
event, a malformed colour, and events in another time zone. During the design these were also
checked by eye: late and night syncs, midnight crossing, carried-over events, a quiet day, the
year boundary ("1月" day label, "逾期 649 天 · 2025年1月1日", "2027年3月1日"), exactly-24 h and
48 h events, and to-do lists of 3, 10, 14 and 15 tasks.

## 9. Message board pages (`render_board`, `render_message`)

Input: the notes, newest first (`Note(id, text, at, color)`, see `python/src/ulani_epaper/notes.py`;
colours yellow / orange / green / blue / red), and the time zone. No clock: a note's time is its
own `at`, shown as `M/D HH:MM` ("10/12 14:03"). Text goes through the same contract as above;
a note's own line breaks start new lines, lines that are empty after cleaning are dropped, and
a note with nothing drawable shows "（無法顯示的留言）". Line pitch is 1.25 x the text size;
the first baseline sits the height of a bold "國" below the text box top.

### 9.1 Board (`render_board`, 留言板)
* Header: "留言板" 32 Bold black at (28, 56); right-aligned at (772, 56) "N 則" 18 Regular, or
  "最新 6 則，共 N 則" when there are more than 6 notes (nothing when there are none).
* Cards: the newest 6, in x 28..772, y 84..462 with 16 px gaps; 1: full width; 2: two columns;
  3: three columns; 4: 2 x 2; 5-6: 3 x 2, left to right then top to bottom. Each cell is
  `x0 = 28 + c(cw + 16)`, `x1 = round(x0 + cw) − 1` (y likewise), the box rounded to whole pixels.
* Card: rounded rectangle, radius 12, in the note colour (yellow: 1 px black keyline). Text and
  time black on yellow / orange / green, white on blue / red (white on green would have a
  contrast of 1.4). Padding 14.
* Time: 18 Regular, left at x0 + 14, baseline y1 + 1 − 16.
* Text: Bold, the largest of 44, 36, 30, 26, 22, 20 at which the whole note fits in
  (card width − 28) x (time top − 10 − (y0 + 14)); otherwise 20 with "…" closing the last line.
  A size at which a paragraph ends on a line of one character, perhaps with closing
  punctuation ("生日快" over "樂！"), is passed over for the next size that fits without one;
  when no size does, the largest that fits is used after all.

### 9.2 One big message (`render_message`, 大字留言)
* Header: "留言" 28 Bold red at (28, 56); the newest note's time 18 Regular right-aligned at (772, 56).
* Text: Bold, the largest of 120, 96, 80, 64, 52, 44, 36, 30 at which the whole note fits in
  744 x 378; otherwise 30 with "…". When it fits on more lines than it has paragraphs, the width
  is narrowed (binary search, never below the widest word) to the least that keeps the same
  number of lines, so the lines are even. Each line centred on x = 400; the block is centred in
  y 84..462 using the "國" box (top of the first line to the bottom of the last).
  Colour: red / blue as the note; black for yellow / orange / green.

### 9.3 Empty state (both)
Yellow rounded square 68 x 68 (radius 10, black keyline) centred at (400, 222) with three black
3 px bars (36, 36, 22 px long, from x 382, centred on y 210, 222, 234); "還沒有留言" 30 Bold
centred at baseline 304; "在 Paperhue 輸入留言，就會顯示在這裡" 20 Regular centred at 338.

Goldens: fixtures `shared/layouts/board/*.json` ("utc_offset" + "notes"), renders and drawn
strings in `shared/layouts/board/golden/`, checked by `python/tests/test_board_layouts.py`.
