> Cross-platform spec for the message board. The Python code in python/ is the reference implementation; goldens are in shared/layouts/board/.

# Message board (留言板) spec — Paperhue v0.3.0, Python reference

The owner wants to put a short message on the device quickly. Two page
kinds, chosen per page like the calendar pages:

| kind      | label (zh-TW) | shows                                             |
|-----------|---------------|---------------------------------------------------|
| `board`   | 留言板        | sticky notes, newest first, up to 6               |
| `message` | 大字留言      | only the newest note, as large as it fits         |

Notes are written by the owner, so storing them locally is fine (unlike
calendar data, which is never stored).

## Store: `ulani_epaper/notes.py`

- File: `config_dir()/notes.json`, written atomically like settings.json:
  `{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "...", "at": "2026-10-12T14:03:00+08:00", "color": "yellow"}]}`
  newest first.
- `Note(id: str, text: str, at: str, color: str = "yellow")`; `at` is ISO 8601 with offset.
- `NOTE_COLOURS = ("yellow", "orange", "green", "blue", "red")`, default yellow.
- `MAX_NOTES = 50` (adding drops the oldest), `MAX_TEXT = 300` characters
  after NFC + strip; at most 8 lines; empty text is an error.
- `load(path=None) -> list[Note]` (missing file -> []; unreadable/invalid ->
  UlaniError naming the file, never silently overwritten),
  `save(notes, path=None)`, `add(text, color="yellow", now=None, path=None) -> Note`,
  `remove(key, path=None) -> Note` (key = id, or 1-based position in the
  newest-first list), `clear(path=None) -> int`.
- ids: 8 hex chars from `secrets.token_hex(4)`, unique within the file.

## Drawing: `layouts.render_board(notes, tz)` and `layouts.render_message(notes, tz)`

Same rules as the calendar pages: 800x480, 7 panel colours only, no
anti-aliasing, deterministic (no clock: times come from `note.at`, shown in
`tz` as `M/D HH:MM`, e.g. `10/12 14:03`), all text through the page
primitives (fonts.clean, kinsoku `_wrap`, `_fit`), `drawn_texts()` works.

Board (`render_board`):
- Header on `HEADER_BASE`: `留言板` bold 32 left; right-aligned `N 則` (18).
  With more than 6 notes the right side reads `最新 6 則，共 N 則`.
- Cards: newest first. 1 note: one full-width card; 2: two columns; 3: three
  columns; 4: 2 x 2; 5-6: 3 x 2 (reading order left to right, top to bottom).
  Area: x `MARGIN`..`W - MARGIN`, y 84..`BOTTOM`, gap 16 px.
- Card: rounded rectangle radius 12 filled with the note colour (yellow
  gets a black keyline like the calendar dots). Text colour black on
  yellow / orange / green, white on blue / red (WCAG contrast at least
  4.0; white on green would be 1.4). Inner padding 14 px.
- Card text bold, largest of 44, 36, 30, 26, 22, 20 px at which the wrapped
  text fits completely above the footer; otherwise 20 px with an ellipsis
  on the last line. A size at which a paragraph would end on a line of one
  character, perhaps with closing punctuation (`生日快` over `樂！`), is
  passed over for the next size that fits without one; if no size does,
  the largest that fits is used after all. Footer: the time, 18 px,
  bottom-left inside the card.
- Untitled-style fallbacks: text that is empty after fonts.clean ->
  `（無法顯示的留言）`.
- Empty state: centred `還沒有留言` (30 bold) and
  `在 Paperhue 輸入留言，就會顯示在這裡` (20).

Message (`render_message`):
- Header on `HEADER_BASE`: `留言` bold 28 in red, the time right-aligned (18).
- The newest note's text centred (horizontally per line, block vertically)
  in x `MARGIN`..`W - MARGIN`, y 84..`BOTTOM`, bold, largest of 120, 96,
  80, 64, 52, 44, 36, 30 px that fits completely; otherwise 30 px with an
  ellipsis. Line pitch 1.25 x size. Colour: the note colour for red /
  blue, black for yellow / orange / green (pale on white).
- Empty state: same as the board.

Goldens: fixtures `shared/layouts/board/*.json` (notes + tz offset) for
empty, one short, one long (wraps and shrinks), six mixed colours, eight
(overflow), emoji-only; PNG + TXT for both renderers, written by the same
`write_golden` mechanism and checked by tests like the calendar goldens.

## Settings and sync

- `config.PAGE_KINDS` gains `board`, `message`; `PAGE_NAMES` gains
  `留言板`, `大字留言`. Defaults unchanged.
- `sync.sync()` draws every non-photo page. Board pages come from
  `notes.load()`; feeds are fetched only when a calendar page (month /
  agenda / todo) exists, so a setup with only board pages never raises
  NoFeeds. The scheduled sync therefore also redraws boards (unchanged
  pages are skipped by the device probe).
- `sync.post(settings=None, *, show="auto", push=..., progress=None,
  dry_run=False, **connect) -> SyncReport`: draws only the board / message
  pages (no feed download, works offline), pushes them and switches the
  display. `show`: "auto" = the first `message` page, else the first
  `board` page; "board" / "message" = the first page of that kind;
  "none" = do not switch. Raises UlaniError
  (`沒有留言頁：先把某一頁設為「留言板」或「大字留言」`) when no page has a
  board kind.

## Switching the display in one connection

`client.Calendar.push_pages(frames, progress=None, busy_timeout=60.0, show=None)`:
when `show` is given and differs from the page on screen, upload every
page except the one on screen first, then `show(show)` (one panel refresh),
then the previously shown page if it is in `frames` (no longer on screen,
so no second refresh; the upload waits for the refresh with the existing
busy retry). When `show` is the page on screen or None, behaviour is as
today. `push.push_frames(..., show=None)` passes it through.
PushEvent gets a `"switching"` phase for the show step.

## CLI

`ulani note add TEXT [--color C] [--show auto|board|message|none] [--no-push]`,
`ulani note list`, `ulani note remove ID_OR_N [--no-push]`,
`ulani note clear [--no-push]`. add/remove/clear save, then post (remove and
clear use show="none"). `--no-push` only saves. `ulani pages 4=board` works
with the new kinds. `\n` in TEXT means a line break (like `ulani text`).

## Windows app

- Page selector (顯示) gains 留言板 and 大字留言; their tiles show the
  drawing from the saved notes at once (no network).
- A 留言… button next to 行事曆來源… opens a dialog: multi-line text box
  with a live `N / 300` counter, colour choice (黃 橘 綠 藍 紅, default
  黃), `新增留言` (saves the note and redraws the board tiles), the list of
  notes (time + first line, newest first), `刪除` for the selected note and
  `全部清除` (asks first). The dialog only saves: the main window's
  `推送到裝置` (every page, `sync.push_all`) or a board page's `更新這頁`
  sends the board pages, without switching the display.
- If no page is a board kind, the dialog explains how to set one and the
  add button is disabled.
- All strings Traditional Chinese, matching the existing tone.

## Tests

Store (round trip, limits, ids, corrupt file, remove by id / position,
clear), renderers (goldens, palette only, deterministic, text goldens,
fit / shrink / ellipsis, colours), sync (board-only setup without feeds,
mixed setup fetches feeds once, post show modes, error without board
pages), client push_pages with show (order, single refresh, unchanged
target still switches, show == shown), CLI note commands (with fakes), GUI
dialog (post, delete, clear, disabled without board pages) with fakes.
No Bluetooth, no network.
