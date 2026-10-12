"""Apple-style calendar pages for the 7.3" colour e-paper device (800 x 480, 7 colours).

Direction: "Apple widgets". Each page is laid out like one large iOS / macOS
widget, with generous white space, hierarchy from type size and weight, and
almost no lines.

* render_month:  today panel (red weekday, huge numeral, today's events, then
                 tomorrow or the next event) beside a mini month with coloured
                 event dots (Calendar widget).
* render_agenda: "Up Next" hero, the rest of today, and the following six days
                 as a list with a start/end time column (Calendar list widget).
* render_day:    one day: big date and weekday, today's events.
* render_monthgrid: the whole month as a grid: Sundays in red, event dots, short
                 titles where the cells are tall enough.
* render_todo:   Reminders list. Short lists use two-line rows. Long lists are
                 grouped into 逾期 / 今天 / 之後 / 未排定 sections.
* render_board:  message board (留言板): the newest notes as coloured sticky
                 notes in a grid (Notes / Stickies widget).
* render_message: the newest note alone, as large as it fits (大字留言).
* render_card:   a saved card (牌卡): a photo or a plain ink, and text boxes drawn
                 crisp on top, optionally outlined (shared/CARDS.md).

Every calendar page takes an optional ``background``: a photo already dithered to
the panel (load_background). The layout stays; all text is then white with a black
outline, and dots, bars, rings and hairlines get a black outline too.

Output is 800x480 RGB in the 7 panel colours only, with no anti-aliasing.
Time format: 24-hour "09:00" everywhere. Weeks start on Sunday.
Deterministic: nothing reads the clock. "now" is data.fetched_at when it falls
on ``today``, otherwise the start of ``today``; a note's time is its own ``at``.

Port notes: all geometry is in the named constants below. Text is always drawn
with a baseline anchor ("ls" left, "rs" right, "ms" centre). The only drawing
primitives are text, rect, rounded rect, circle, ring, line and dotted line.
"""

from __future__ import annotations

import calendar
import math
import re
from datetime import date, datetime, time, timedelta, tzinfo
from pathlib import Path

from PIL import Image, ImageDraw

from . import cards, config, fonts
from .agenda import AgendaData, Event, Task
from .image import PALETTE, accent, fit, open_image, to_indexed
from .notes import Note
from .protocol import HEIGHT, WIDTH, UlaniError

# =============================================================================
# Canvas, palette, type scale
# =============================================================================

W, H = WIDTH, HEIGHT
RGB = {c.name: c.rgb for c in PALETTE}  # the 7 panel colours, by name
INK, PAPER, RED, BLUE = RGB["black"], RGB["white"], RGB["red"], RGB["blue"]

MARGIN = 28  # left and right page margin
BOTTOM = H - 18  # 462: no ink below this line
HEADER_BASE = 56  # baseline of every page's top line

# Type sizes (px). At 1 bit, CJK below 18 px regular fills in (四 turns solid at
# 16-17 px), so 16 px is used only for the sync stamp and digit-only end times.
SIZE_SYNC = 16
SIZE_END_TIME = 16
SIZE_NOTE = 18  # secondary: times, locations, '還有 N 項', section labels
SIZE_TITLE = 20  # event titles in rows

ELLIPSIS = "…"
SEP = "·"  # metadata separator; the font's U+00B7 is full-width, so no spaces
WEEKDAYS = "一二三四五六日"  # indexed by date.weekday()
UNTITLED = "（無標題）"  # the event or task really has no title
UNDRAWABLE = "（無法顯示的標題）"  # it has one, but only of characters the font lacks (e.g. emoji)

# =============================================================================
# Shared event rows (month panel, agenda)
# =============================================================================

ROW_TEXT_DX = 15  # text x in cards / all-day line (after the 5 px bar or 10 px dot)
DOT_R = 5  # calendar dot radius (10 px dot), also used in the mini month

ALLDAY_H = 34  # one line: ● title ● title +N
ALLDAY_BASE = 22

CARD_H = 56  # two lines: bold title, then "10:00 – 11:30 · 3F 大會議室"
CARD_BAR_W = 5
CARD_BASE1, CARD_BASE2 = 20, 44

LINE_H = 28  # one line: start time | bar | title
LINE_BASE = 22
LINE_BAR_W = 4
LINE_TIME_W = 70  # bar x offset (fits "至01:00" at 18 px = 63 px)
LINE_TITLE_DX = 82

NOTE_H = 28  # '還有 N 項' / '稍早已結束 N 項' on a line of their own
NOTE_BASE = 21
SECTION_GAP = 10  # space above a '明天' / '下一個行程' label
SECTION_H = 26  # the label itself (18 px bold)


# =============================================================================
# Text
# =============================================================================

_LATIN = re.compile(r"[0-9A-Za-zÀ-ɏ]")
_TOKEN = re.compile(r"[0-9A-Za-zÀ-ɏ'’.,:;!?&+#@%/\-]+|\s+|.")  # Latin words stay whole
_NO_LINE_START = set("，。、：；！？）」』》〉】,.:;!?)")


def _font(size: int, bold: bool = False):
    return fonts.load(size, bold)


def _width(s: str, size: int, bold: bool = False) -> float:
    return _font(size, bold).getlength(s)


def _title(text: str) -> str:
    """An event or task title as drawable text (emoji dropped, never empty)."""
    if not (text or "").strip():
        return UNTITLED
    return fonts.clean(text) or UNDRAWABLE


def _fit(text: str, font, width: float) -> str:
    """``text`` cut with an ellipsis to at most ``width`` px, never mid Latin word."""
    if font.getlength(text) <= width:
        return text
    lo, hi = 0, len(text)
    while lo < hi:  # longest prefix that fits with the ellipsis
        mid = (lo + hi + 1) // 2
        if font.getlength(text[:mid].rstrip() + ELLIPSIS) <= width:
            lo = mid
        else:
            hi = mid - 1
    if lo == 0:
        return ELLIPSIS if font.getlength(ELLIPSIS) <= width else ""
    if _LATIN.match(text[lo - 1]) and _LATIN.match(text[lo]):
        space = text.rfind(" ", 0, lo)
        if space > 0 and text[:space].strip():
            lo = space
    return text[:lo].rstrip() + ELLIPSIS


def _wrap(text: str, font, width: float, max_lines: int) -> list[str]:
    """Greedy wrap into at most ``max_lines`` lines; the last one gets '…' if cut."""
    pieces: list[str] = []
    for tok in _TOKEN.findall(text):
        if not tok.isspace() and len(tok) > 1 and font.getlength(tok) > width:
            pieces.extend(tok)
        else:
            pieces.append(tok)
    lines: list[list[str]] = [[]]
    for piece in pieces:
        cur = "".join(lines[-1])
        if not cur.strip() or font.getlength((cur + piece).rstrip()) <= width:
            lines[-1].append(piece)
        elif piece in _NO_LINE_START:
            # punctuation may not start a line: carry the previous character down with it
            # (appending it would overflow the line, and _fit would then cut the line short)
            if len(lines[-1]) > 1 and not lines[-1][-1].isspace():
                lines.append([lines[-1].pop(), piece])
            else:
                lines[-1].append(piece)
        else:
            lines.append([] if piece.isspace() else [piece])
    out = ["".join(line).strip() for line in lines if "".join(line).strip()]
    if len(out) > max_lines:
        rest = "".join("".join(line) for line in lines[max_lines - 1:]).strip()
        out = out[:max_lines - 1] + [_fit(rest, font, width)]
    return [_fit(line, font, width) for line in out]


# =============================================================================
# Drawing primitives
# =============================================================================


def _outline_offsets(r: int) -> list[tuple[int, int]]:
    """Where an outline of radius ``r`` px draws the text: every (dx, dy) with dx^2 + dy^2 <= r^2 + r
    (a rounded square: r = 1 includes the diagonals, r = 3 leaves out (3, 2) and (3, 3))."""
    return [(dx, dy) for dy in range(-r, r + 1) for dx in range(-r, r + 1) if dx * dx + dy * dy <= r * r + r]


OUTLINE_DIV = 16  # outline radius = floor(size / 16 + 0.5) px, at least 1 (cards, and text on a background)


PHOTO_OUTLINE_MAX = 4  # ... but at most this much for text on a calendar background (the big numerals)


def _outline_radius(size: int) -> int:
    return max(1, math.floor(size / OUTLINE_DIV + 0.5))


class _Page:
    #: when a list, every drawn string is appended to it (drawn_texts(), text goldens)
    record: list[str] | None = None

    def __init__(self, background: Image.Image | None = None) -> None:
        """A white page, or (``background``: 800x480 in panel colours) a page on a photo: then text is
        white with a black outline and the colour marks are outlined in black."""
        self.photo = background is not None
        self.img = Image.new("RGB", (W, H), PAPER) if background is None else background.convert("RGB")
        self.draw = ImageDraw.Draw(self.img)
        self.draw.fontmode = "1"  # no anti-aliasing

    def text(self, x: float, y: float, s: str, size: int, bold: bool = False, fill=INK,
             anchor: str = "ls", maxw: float | None = None, outline: int = 0, outline_fill=None) -> float:
        """Draw ``s`` with its baseline at ``y``; returns the drawn advance width.

        Every string goes through fonts.clean(), so no caller can draw emoji or
        control characters; ``maxw`` truncates with an ellipsis. ``outline`` (px)
        first draws the text in ``outline_fill`` at every offset within that
        radius (see _outline_offsets), so the outline is as crisp as the text.
        """
        f = _font(size, bold)
        s = fonts.clean(s)
        if self.photo:
            fill, outline, outline_fill = PAPER, outline or min(PHOTO_OUTLINE_MAX, _outline_radius(size)), INK
        if maxw is not None:
            s = _fit(s, f, maxw)
        if s:
            xy = (round(x), round(y))
            for dx, dy in _outline_offsets(outline) if outline else ():
                self.draw.text((xy[0] + dx, xy[1] + dy), s, font=f, fill=outline_fill, anchor=anchor)
            self.draw.text(xy, s, font=f, fill=fill, anchor=anchor)
            if _Page.record is not None:
                _Page.record.append(s)
        return f.getlength(s)

    def bar(self, x: int, y0: int, y1: int, name: str, w: int) -> None:
        """Calendar colour bar (rounded). Pale yellow gets a black keyline; on a photo every bar does."""
        outline = INK if name == "yellow" and not self.photo else None
        if self.photo:
            self.draw.rounded_rectangle((x - 1, y0 - 1, x + w, y1 + 1), radius=w // 2 + 1, fill=INK)
        self.draw.rounded_rectangle((x, y0, x + w - 1, y1), radius=w // 2, fill=RGB[name], outline=outline)

    def dot(self, cx: float, cy: float, r: int, name: str) -> None:
        """Calendar colour dot. Pale yellow gets a black keyline; on a photo every dot does."""
        outline = INK if name == "yellow" and not self.photo else None
        if self.photo:
            self.disc(cx, cy, r + 1, INK)
        self.draw.ellipse((round(cx - r), round(cy - r), round(cx + r) - 1, round(cy + r) - 1),
                          fill=RGB[name], outline=outline)

    def disc(self, cx: float, cy: float, r: int, fill) -> None:
        if self.photo and fill != INK:
            self.disc(cx, cy, r + 1, INK)
        self.draw.ellipse((round(cx - r), round(cy - r), round(cx + r) - 1, round(cy + r) - 1), fill=fill)

    def ring(self, cx: float, cy: float, r: int, colour, width: int = 2) -> None:
        if self.photo:  # black ink is white on a photo, like the text
            self.draw.ellipse((round(cx - r) - 1, round(cy - r) - 1, round(cx + r), round(cy + r)),
                              outline=INK, width=width + 2)
            colour = PAPER if colour == INK else colour
        self.draw.ellipse((round(cx - r), round(cy - r), round(cx + r) - 1, round(cy + r) - 1),
                          outline=colour, width=width)

    def rect(self, x0: int, y0: int, x1: int, y1: int, fill=INK) -> None:
        self.draw.rectangle((x0, y0, x1, y1), fill=fill)

    def line(self, points: list[tuple[int, int]], fill, width: int) -> None:
        self.draw.line(points, fill=fill, width=width)

    def panel(self, x0: int, y0: int, x1: int, y1: int, name: str, radius: int) -> None:
        """Rounded card in a panel colour (inclusive box). Pale yellow gets a black keyline."""
        outline = INK if name == "yellow" else None
        self.draw.rounded_rectangle((x0, y0, x1, y1), radius=radius, fill=RGB[name], outline=outline)

    def plus(self, px: int, dy: int, size: int) -> None:
        """The '+' mark (2 px strokes, ``size`` wide) with its left edge at ``px``, centred on row ``dy``."""
        half = size // 2
        strokes = ((px, dy - 1, px + size - 1, dy), (px + half - 1, dy - half - 1, px + half, dy + half - 1))
        if self.photo:
            for x0, y0, x1, y1 in strokes:
                self.draw.rectangle((x0 - 1, y0 - 1, x1 + 1, y1 + 1), fill=INK)
        for stroke in strokes:
            self.draw.rectangle(stroke, fill=PAPER if self.photo else INK)

    def _hairline(self, points: list[tuple[int, int]], side: tuple[int, int]) -> None:
        if self.photo:  # white dots between two black ones
            self.draw.point([(x + side[0] * k, y + side[1] * k) for x, y in points for k in (-1, 1)], fill=INK)
        self.draw.point(points, fill=PAPER if self.photo else INK)

    def hairline_h(self, x0: int, x1: int, y: int) -> None:
        """'Grey' hairline: every other pixel black (reads light at desk distance)."""
        self._hairline([(x, y) for x in range(x0, x1 + 1, 2)], (0, 1))

    def hairline_v(self, x: int, y0: int, y1: int) -> None:
        self._hairline([(x, y) for y in range(y0, y1 + 1, 2)], (1, 0))


# =============================================================================
# Dates and events
# =============================================================================


def _hm(dt: datetime) -> str:
    return f"{dt.hour:02d}:{dt.minute:02d}"


def _md(d: date) -> str:
    return f"{d.month}月{d.day}日"


def _md_year(d: date, ref: date) -> str:
    """'10月15日', or '2027年3月1日' when the year differs from ``ref``."""
    return _md(d) if d.year == ref.year else f"{d.year}年{_md(d)}"


def _weekday_long(d: date) -> str:
    return "星期" + WEEKDAYS[d.weekday()]


def _weekday_short(d: date) -> str:
    return "週" + WEEKDAYS[d.weekday()]


def _more(n: int) -> str:
    return f"還有 {n} 項"


def _day_bounds(day: date, tz: tzinfo) -> tuple[datetime, datetime]:
    return datetime.combine(day, time(), tz), datetime.combine(day + timedelta(days=1), time(), tz)


def _local(e: Event, tz: tzinfo) -> tuple[datetime, datetime]:
    """Event start/end as local datetimes (all-day dates become local midnights)."""
    if e.all_day:
        return datetime.combine(e.start, time(), tz), datetime.combine(e.end, time(), tz)
    return e.start.astimezone(tz), e.end.astimezone(tz)


def _covers_day(e: Event, day: date, tz: tzinfo) -> bool:
    """All-day, or a timed event that spans the whole of ``day`` (shown like all-day)."""
    if e.all_day:
        return True
    s, en = _local(e, tz)
    ds, de = _day_bounds(day, tz)
    return s <= ds and en >= de


def _pending(e: Event, now: datetime, tz: tzinfo) -> bool:
    """Not over yet at ``now`` (a zero-length event is pending until it starts)."""
    s, en = _local(e, tz)
    return en > now or (s == en and s >= now)


def _span_note(e: Event, day: date, tz: tzinfo) -> str:
    """'第 2 天，共 3 天' for an event spanning several days, else ''."""
    s, en = _local(e, tz)
    first = s.date()
    last = (en - timedelta(microseconds=1)).date() if en > s else first
    total = (last - first).days + 1
    if total <= 1:
        return ""
    return f"第 {(day - first).days + 1} 天，共 {total} 天"


def _start_label(e: Event, day: date, tz: tzinfo) -> str:
    """Time column, line 1: 'HH:MM', '全天', or '至HH:MM' for a carried-over event."""
    if _covers_day(e, day, tz):
        return "全天"
    s, en = _local(e, tz)
    if s < _day_bounds(day, tz)[0]:
        return "至" + _hm(en)
    return _hm(s)


def _end_label(e: Event, day: date, tz: tzinfo) -> str:
    """Time column, line 2: the end time, or the end date 'M/D' when a bare time would mislead.

    'HH:MM' if it ends today (00:00 for midnight) or early next day before its
    start time (23:00 over 01:00 can only mean the next morning); otherwise
    'M/D'. Empty for all-day, carried-over and zero-length events.
    """
    if _covers_day(e, day, tz):
        return ""
    s, en = _local(e, tz)
    if s == en or s < _day_bounds(day, tz)[0]:
        return ""
    if en <= _day_bounds(day, tz)[1]:
        return _hm(en)
    if en.date() == day + timedelta(days=1) and en.time() < s.time():
        return _hm(en)
    return f"{en.month}/{en.day}"


def _is_continuation(e: Event, day: date, tz: tzinfo) -> bool:
    """Started on an earlier day (and does not cover ``day``): shown as '至HH:MM'."""
    return not _covers_day(e, day, tz) and _local(e, tz)[0] < _day_bounds(day, tz)[0]


def _range_text(e: Event, day: date, tz: tzinfo) -> str:
    """Time range as seen on ``day``, with no words relative to the reader's today:

    '10:00 – 11:30', '23:00 – 00:00', '23:00 – 隔天 01:00', '20:00 – 12月31日 20:00',
    '至 01:00' (carried over from an earlier day), '全天' / '全天·第 2 天，共 3 天'.
    """
    if _covers_day(e, day, tz):
        note = _span_note(e, day, tz)
        return f"全天{SEP}{note}" if note else "全天"
    s, en = _local(e, tz)
    if s == en:
        return _hm(s)
    ds, de = _day_bounds(day, tz)
    if s < ds:
        return f"至 {_hm(en)}"
    if en <= de:
        return f"{_hm(s)} – {_hm(en)}"
    if en.date() == day + timedelta(days=1):
        return f"{_hm(s)} – 隔天 {_hm(en)}"
    return f"{_hm(s)} – {_md_year(en.date(), day)} {_hm(en)}"


def _detail(e: Event, day: date, tz: tzinfo) -> str:
    """Second line of a card: time range, then the location if there is one."""
    where = fonts.clean(e.location or "")
    return _range_text(e, day, tz) + (SEP + where if where else "")


def _now(data: AgendaData, today: date, tz: tzinfo) -> datetime:
    """The sync time if it is on ``today``, else the start of ``today``."""
    ds, de = _day_bounds(today, tz)
    f = data.fetched_at
    if f is not None and f.tzinfo is not None:
        t = f.astimezone(tz)
        if ds <= t < de:
            return t
    return ds


def _sync_text(data: AgendaData, today: date, tz: tzinfo) -> str:
    """'更新於 10/12': the date only, never the time, so a page whose content did
    not change between two syncs on the same day is the same image (the device
    then skips it instead of refreshing the panel). A page still on screen days
    later shows its age."""
    f = data.fetched_at
    if f is None:
        return ""
    t = f.astimezone(tz) if f.tzinfo is not None else f
    if t.year == today.year:
        return f"更新於 {t.month}/{t.day}"
    return f"更新於 {t.year}/{t.month}/{t.day}"


def _split_day(events: list[Event], day: date, tz: tzinfo, now: datetime | None):
    """(all-day-like events, pending timed events, number of ended timed events)."""
    allday = [e for e in events if _covers_day(e, day, tz)]
    timed = [e for e in events if not _covers_day(e, day, tz)]
    pending = timed if now is None else [e for e in timed if _pending(e, now, tz)]
    return allday, pending, len(timed) - len(pending)


def _next_event(data: AgendaData, after: date, tz: tzinfo) -> Event | None:
    """The first event that starts on a day after ``after``."""
    start = _day_bounds(after, tz)[1]
    later = [e for e in data.events if e.start_in(tz) >= start]
    return min(later, key=lambda e: (e.start_in(tz), not e.all_day, e.title), default=None)


# =============================================================================
# Shared row drawing
# =============================================================================


def _allday_line(p: _Page, x: int, y: int, w: int, events: list[Event], day: date, tz: tzinfo) -> int:
    """All of a day's all-day events on one line. Returns the new y.

    One event:  ● 墾丁三日遊  第 3 天，共 3 天   (the note only if it fits)
    Several:    ● 墾丁三日遊  ● 咖啡日  +1       (as many as fit, then +N)
    """
    base = y + ALLDAY_BASE
    cy = base - 8  # dot centre at the middle of the CJK glyphs
    titles = [_title(e.title) for e in events]
    names = [accent(e.color) for e in events]
    n = len(events)
    gap = 16  # between items
    if n == 1:
        p.dot(x + DOT_R, cy, DOT_R, names[0])
        tw = p.text(x + ROW_TEXT_DX, base, titles[0], SIZE_TITLE, True, maxw=w - ROW_TEXT_DX)
        note = _span_note(events[0], day, tz)
        if note and ROW_TEXT_DX + tw + 12 + _width(note, SIZE_NOTE) <= w:
            p.text(x + ROW_TEXT_DX + tw + 12, base, note, SIZE_NOTE)
        return y + ALLDAY_H
    item_w = [ROW_TEXT_DX + _width(t, SIZE_TITLE, True) for t in titles]

    def plus_w(rest: int) -> float:
        return gap + _width(f"+{rest}", SIZE_NOTE) if rest else 0

    k = 1  # at least one item (truncated if needed)
    while k < n and sum(item_w[:k + 1]) + gap * k + plus_w(n - k - 1) <= w:
        k += 1
    cx = x
    for i in range(k):
        p.dot(cx + DOT_R, cy, DOT_R, names[i])
        room = w - (cx - x) - ROW_TEXT_DX - (plus_w(n - k) if i == k - 1 else 0)
        tw = p.text(cx + ROW_TEXT_DX, base, titles[i], SIZE_TITLE, True, maxw=room)
        cx += ROW_TEXT_DX + tw + gap
    if k < n:
        p.text(cx, base, f"+{n - k}", SIZE_NOTE)
    return y + ALLDAY_H


def _card(p: _Page, x: int, y: int, w: int, e: Event, day: date, tz: tzinfo) -> None:
    """Two-line widget row: colour bar, bold title, 'time range · location'."""
    p.bar(x, y + 4, y + CARD_H - 11, accent(e.color), CARD_BAR_W)
    p.text(x + ROW_TEXT_DX, y + CARD_BASE1, _title(e.title), SIZE_TITLE, True, maxw=w - ROW_TEXT_DX)
    p.text(x + ROW_TEXT_DX, y + CARD_BASE2, _detail(e, day, tz), SIZE_NOTE, maxw=w - ROW_TEXT_DX)


def _line_row(p: _Page, x: int, y: int, w: int, e: Event, day: date, tz: tzinfo, more: str = "",
              bold: bool = False) -> None:
    """One-line row: start time, colour bar, title, optional right-aligned '還有 N 項'.

    Titles are bold in the left-hand 'today' lists and regular in the six-day list.
    """
    base = y + LINE_BASE
    p.text(x, base, _start_label(e, day, tz), SIZE_NOTE)
    p.bar(x + LINE_TIME_W, y + 5, y + LINE_H - 4, accent(e.color), LINE_BAR_W)
    mw = p.text(x + w, base, more, SIZE_NOTE, anchor="rs") + 12 if more else 0
    p.text(x + LINE_TITLE_DX, base, _title(e.title), SIZE_TITLE, bold, maxw=w - LINE_TITLE_DX - mw)


def _note(p: _Page, x: int, y: int, w: int, text: str) -> int:
    p.text(x, y + NOTE_BASE, text, SIZE_NOTE, maxw=w)
    return y + NOTE_H


def _timed_list(p: _Page, x: int, y: int, w: int, bottom: int, events: list[Event], day: date,
                tz: tzinfo) -> tuple[int, int]:
    """Timed events as cards if all fit, else one-line rows, else rows + '還有 N 項'.

    Returns (new y, x where a following note should start).
    """
    n = len(events)
    if n == 0:
        return y, x + ROW_TEXT_DX
    avail = bottom - y
    if n * CARD_H <= avail:
        for e in events:
            _card(p, x, y, w, e, day, tz)
            y += CARD_H
        return y, x + ROW_TEXT_DX
    k = n if n * LINE_H <= avail else max(0, (avail - NOTE_H) // LINE_H)
    for e in events[:k]:
        _line_row(p, x, y, w, e, day, tz, bold=True)
        y += LINE_H
    if k < n and y + NOTE_H <= bottom:
        y = _note(p, x, y, w, _more(n - k))
    return y, x


def _section_label(p: _Page, x: int, y: int, text: str, fill=INK) -> int:
    p.text(x, y + SECTION_GAP + 18, text, SIZE_NOTE, True, fill)
    return y + SECTION_GAP + SECTION_H


def _next_card(p: _Page, x: int, y: int, w: int, e: Event, today: date, tz: tzinfo) -> int:
    """'下一個行程' block: label, then a card whose second line names the day.

    Second line: '明天 08:00·鼎泰豐' / '10月1日 週四 09:30' / '2027年1月1日 週五 全天'.
    """
    y = _section_label(p, x, y, "下一個行程")
    start = e.start_in(tz)
    d = start.date()
    day = "明天" if d == today + timedelta(days=1) else f"{_md_year(d, today)} {_weekday_short(d)}"
    where = fonts.clean(e.location or "")
    detail = f"{day} {_start_label(e, d, tz)}" + (SEP + where if where else "")
    p.bar(x, y + 4, y + CARD_H - 11, accent(e.color), CARD_BAR_W)
    p.text(x + ROW_TEXT_DX, y + CARD_BASE1, _title(e.title), SIZE_TITLE, True, maxw=w - ROW_TEXT_DX)
    p.text(x + ROW_TEXT_DX, y + CARD_BASE2, detail, SIZE_NOTE, maxw=w - ROW_TEXT_DX)
    return y + CARD_H


# =============================================================================
# Month
# =============================================================================

MONTH_PANEL_X = MARGIN
MONTH_PANEL_W = 262
MONTH_WEEKDAY_SIZE = 26  # 星期一, red bold
MONTH_NUMERAL_SIZE = 128  # today's date, bold
MONTH_NUMERAL_BASE = 168
MONTH_LIST_TOP = 196
MONTH_MESSAGE_SIZE = 22  # 今天沒有行程

MONTH_GRID_X0, MONTH_GRID_X1 = 326, W - MARGIN + 6  # 7 columns of ~64.6 px
MONTH_TITLE_SIZE = 28  # 2026年 regular + 10月 bold red
MONTH_DOW_BASE = 98
MONTH_DOW_SIZE = 18
MONTH_GRID_TOP = 110
MONTH_GRID_BOTTOM = BOTTOM + 2
MONTH_ROW_MAX = 84  # row pitch = min(84, 354 / weeks): 84 (4 weeks), 70.8 (5), 59 (6)
MONTH_DAY_SIZE = 22
MONTH_DAY_CY = 22  # numeral centre below the row top
MONTH_TODAY_R = 19  # red disc behind today's numeral
MONTH_DOT_DY = 28  # dot row below the numeral centre
MONTH_DOT_PITCH = 12  # 10 px dots, 2 px apart
MONTH_DOTS_MAX = 4
MONTH_PLUS = 9  # '+' mark (2 px strokes) when a day has more events than dots


def _month_dots(events: list[Event]) -> tuple[list[str], bool]:
    """Up to 4 dots: each calendar colour once first, then repeats to show load.

    Dots are grouped by colour in order of first appearance; the flag says a
    '+' follows because the day has more events than dots.
    """
    seq = [accent(e.color) for e in events]
    distinct = list(dict.fromkeys(seq))
    extra = list(seq)
    for name in distinct:
        extra.remove(name)
    dots = (distinct + extra)[:MONTH_DOTS_MAX]
    dots.sort(key=distinct.index)
    return dots, len(events) > MONTH_DOTS_MAX


def _month_panel(p: _Page, data: AgendaData, today: date, tz: tzinfo) -> None:
    x, w = MONTH_PANEL_X, MONTH_PANEL_W
    p.text(x, HEADER_BASE, _weekday_long(today), MONTH_WEEKDAY_SIZE, True, RED)
    p.text(x, MONTH_NUMERAL_BASE, str(today.day), MONTH_NUMERAL_SIZE, True)

    y = MONTH_LIST_TOP
    events = data.events_on(today, tz)
    allday, pending, ended = _split_day(events, today, tz, _now(data, today, tz))
    if not events:
        p.text(x, y + 24, "今天沒有行程", MONTH_MESSAGE_SIZE, True)
        y += 34
    else:
        if allday:
            y = _allday_line(p, x, y, w, allday, today, tz)
        if not pending and ended:
            p.text(x, y + 24, "今天沒有其他行程", MONTH_MESSAGE_SIZE, True)
            y += 34
        y, note_x = _timed_list(p, x, y, w, BOTTOM - (NOTE_H if ended else 0), pending, today, tz)
        if ended:
            y = _note(p, note_x, y, w, f"稍早已結束 {ended} 項")

    # Like the Apple widget: if today leaves room, continue with tomorrow.
    tomorrow = today + timedelta(days=1)
    t_events = data.events_on(tomorrow, tz)
    if t_events:
        t_allday, t_timed, _ = _split_day(t_events, tomorrow, tz, None)
        need = SECTION_GAP + SECTION_H + (ALLDAY_H if t_allday else 0) + (LINE_H if t_timed else 0)
        if y + need <= BOTTOM:
            y = _section_label(p, x, y, "明天")
            if t_allday:
                y = _allday_line(p, x, y, w, t_allday, tomorrow, tz)
            _timed_list(p, x, y, w, BOTTOM, t_timed, tomorrow, tz)
        return
    if events:
        return
    # Nothing today or tomorrow: name the next event instead of an empty panel.
    nxt = _next_event(data, today, tz)
    if nxt is None:
        p.text(x, y + 22, "近期沒有行程", SIZE_NOTE)  # not "none at all": the data covers only weeks ahead
    else:
        _next_card(p, x, y, w, nxt, today, tz)


def _month_grid(p: _Page, data: AgendaData, today: date, tz: tzinfo) -> None:
    x0, x1 = MONTH_GRID_X0, MONTH_GRID_X1
    cw = (x1 - x0) / 7
    cxs = [x0 + cw * (i + 0.5) for i in range(7)]

    # Title "2026年10月": year regular black, month bold red (zh-TW Calendar order).
    tx = cxs[0] - 9
    tx += p.text(tx, HEADER_BASE, f"{today.year}年", MONTH_TITLE_SIZE)
    p.text(tx, HEADER_BASE, f"{today.month}月", MONTH_TITLE_SIZE, True, RED)
    sync = _sync_text(data, today, tz)
    if sync:
        p.text(W - MARGIN, HEADER_BASE, sync, SIZE_SYNC, anchor="rs")

    for i, ch in enumerate("日一二三四五六"):
        p.text(cxs[i], MONTH_DOW_BASE, ch, MONTH_DOW_SIZE, anchor="ms")

    weeks = calendar.Calendar(firstweekday=6).monthdatescalendar(today.year, today.month)
    rh = min(MONTH_ROW_MAX, (MONTH_GRID_BOTTOM - MONTH_GRID_TOP) / len(weeks))
    top, bottom = _font(MONTH_DAY_SIZE).getbbox("0", anchor="ls")[1::2]
    for r, week in enumerate(weeks):
        cy = MONTH_GRID_TOP + rh * r + MONTH_DAY_CY
        base = cy - (top + bottom) / 2  # optically centre the digits on cy
        for c, d in enumerate(week):
            if d.month != today.month:
                continue  # days outside the month stay blank, as on iPhone
            cx = cxs[c]
            if d == today:
                p.disc(cx, cy, MONTH_TODAY_R, RED)
                p.text(cx, base, str(d.day), MONTH_DAY_SIZE, True, PAPER, anchor="ms")
            else:
                p.text(cx, base, str(d.day), MONTH_DAY_SIZE, False, INK, anchor="ms")
            _draw_dots(p, cx, round(cy + MONTH_DOT_DY), *_month_dots(data.events_on(d, tz)))


def _draw_dots(p: _Page, cx: float, dy: int, dots: list[str], plus: bool) -> None:
    """The day's dots (and the '+') centred on ``cx``, on row ``dy``."""
    if not dots:
        return
    group = MONTH_DOT_PITCH * len(dots) - (MONTH_DOT_PITCH - 2 * DOT_R)
    if plus:
        group += 4 + MONTH_PLUS
    gx = round(cx - group / 2)
    for j, name in enumerate(dots):
        p.dot(gx + DOT_R + MONTH_DOT_PITCH * j, dy, DOT_R, name)
    if plus:
        p.plus(gx + group - MONTH_PLUS, dy, MONTH_PLUS)


def render_month(data: AgendaData, today: date, tz: tzinfo, background: Image.Image | None = None) -> Image.Image:
    """Today panel on the left, the month containing ``today`` on the right."""
    p = _Page(background)
    _month_panel(p, data, today, tz)
    _month_grid(p, data, today, tz)
    return p.img


# =============================================================================
# Agenda
# =============================================================================

AGENDA_HEADER_SIZE = 28  # 星期一 (red) 10月12日 (black), bold
AGENDA_TOP = 84
AGENDA_LEFT_X, AGENDA_LEFT_W = MARGIN, 326
AGENDA_DIVIDER_X = 380
AGENDA_RIGHT_X = 404
AGENDA_RIGHT_W = W - MARGIN - AGENDA_RIGHT_X  # 368

HERO_LABEL_SIZE = 18  # 接下來 / 進行中, red bold
HERO_TITLE_SIZE = 40  # bold, up to 2 lines
HERO_TITLE_PITCH = 52
HERO_TIME_SIZE = 26
HERO_PLACE_SIZE = 20
HERO_BAR_W = 7
HERO_TEXT_DX = 22
HERO_MESSAGE_SIZE = 30  # 今天沒有行程

DAY_LABEL_W = 54  # day number column of the six-day list
DAY_NUMBER_SIZE = 26  # bold
DAY_LABEL_H = 50  # number + 明天 / 週三 / 11月
DAY_SUB_BASE = 44
DAY_GAP = 6
FULL_ROW_H = 50  # list row with end time / location on a second line
FULL_BASE2 = 44


def _agenda_header(p: _Page, data: AgendaData, today: date, tz: tzinfo) -> None:
    x = MARGIN
    x += p.text(x, HEADER_BASE, _weekday_long(today), AGENDA_HEADER_SIZE, True, RED) + 12
    last = today + timedelta(days=6)
    label = _md(today) if last.year == today.year else f"{today.year}年{_md(today)}"
    p.text(x, HEADER_BASE, label, AGENDA_HEADER_SIZE, True)
    sync = _sync_text(data, today, tz)
    if sync:
        p.text(W - MARGIN, HEADER_BASE, sync, SIZE_SYNC, anchor="rs")


def _agenda_empty(p: _Page, data: AgendaData, today: date, tz: tzinfo) -> Image.Image:
    """Nothing all week: a Calendar-icon date and one calm message."""
    cx = W // 2
    p.text(cx, 100, _weekday_long(today), 30, True, RED, anchor="ms")
    p.text(cx, 232, str(today.day), 128, True, anchor="ms")
    p.text(cx, 274, f"{today.year}年{_md(today)}", 22, anchor="ms")
    p.hairline_h(cx - 150, cx + 150, 298)
    p.text(cx, 346, "今天沒有行程", 30, True, anchor="ms")
    p.text(cx, 380, "接下來 6 天也沒有行程", 20, anchor="ms")
    sync = _sync_text(data, today, tz)
    if sync:
        p.text(W - MARGIN, HEADER_BASE, sync, SIZE_SYNC, anchor="rs")
    return p.img


def _agenda_today(p: _Page, data: AgendaData, today: date, tz: tzinfo, events: list[Event]) -> None:
    """Left column: all-day line, Up Next hero, the rest of today, ended count."""
    x, w = AGENDA_LEFT_X, AGENDA_LEFT_W
    now = _now(data, today, tz)
    allday, pending, ended = _split_day(events, today, tz, now)
    y = AGENDA_TOP
    if allday:
        y = _allday_line(p, x, y, w, allday, today, tz) + 6

    hero = pending[0] if pending else None
    if hero is not None:
        s, en = _local(hero, tz)
        p.text(x, y + 18, "進行中" if s <= now < en else "接下來", HERO_LABEL_SIZE, True, RED)
        y += 28
        y0 = y
        for line in _wrap(_title(hero.title), _font(HERO_TITLE_SIZE, True), w - HERO_TEXT_DX, 2):
            p.text(x + HERO_TEXT_DX, y + 42, line, HERO_TITLE_SIZE, True)
            y += HERO_TITLE_PITCH
        p.text(x + HERO_TEXT_DX, y + 28, _range_text(hero, today, tz), HERO_TIME_SIZE, maxw=w - HERO_TEXT_DX)
        y += 36
        where = fonts.clean(hero.location or "")
        if where:
            p.text(x + HERO_TEXT_DX, y + 24, where, HERO_PLACE_SIZE, maxw=w - HERO_TEXT_DX)
            y += 32
        p.bar(x, y0 + 10, y - 6, accent(hero.color), HERO_BAR_W)
        y += 14
    else:
        message = "今天沒有行程" if not events else "今天沒有其他行程"
        p.text(x, y + 34, message, HERO_MESSAGE_SIZE, True)
        y += 56
        if ended:
            y = _note(p, x, y, w, f"稍早已結束 {ended} 項")
            ended = 0
        # Answer "what's next" even when today is done (Apple's Up Next shows tomorrow).
        nxt = _next_event(data, today, tz)
        if nxt is not None and y + SECTION_GAP + SECTION_H + CARD_H <= BOTTOM:
            y = _next_card(p, x, y + 8, w, nxt, today, tz)

    rest = pending[1:]
    reserve = NOTE_H if ended else 0
    note_x = x
    if rest and y + SECTION_H + min(len(rest), 1) * LINE_H + reserve <= BOTTOM:
        p.text(x, y + 18, "今天稍後", SIZE_NOTE, True)
        y, note_x = _timed_list(p, x, y + SECTION_H, w, BOTTOM - reserve, rest, today, tz)
    elif rest:
        y = _note(p, x, y, w, _more(len(rest)))
    if ended and y + NOTE_H <= BOTTOM:
        _note(p, note_x, y, w, f"稍早已結束 {ended} 項")


def _list_row(p: _Page, x: int, y: int, w: int, e: Event, day: date, tz: tzinfo, full: bool,
              more: str = "") -> None:
    """Six-day list row. Compact: start | bar | title. Full adds a second line:
    the end time under the start time and the location under the title."""
    if not full:
        _line_row(p, x, y, w, e, day, tz, more)
        return
    base1, base2 = y + LINE_BASE, y + FULL_BASE2
    p.text(x, base1, _start_label(e, day, tz), SIZE_NOTE)
    p.text(x, base2, _end_label(e, day, tz), SIZE_END_TIME)
    p.bar(x + LINE_TIME_W, y + 5, y + FULL_ROW_H - 6, accent(e.color), LINE_BAR_W)
    tx = x + LINE_TITLE_DX
    p.text(tx, base1, _title(e.title), SIZE_TITLE, maxw=w - LINE_TITLE_DX)
    mw = p.text(x + w, base2, more, SIZE_NOTE, anchor="rs") + 12 if more else 0
    where = fonts.clean(e.location or "")
    if where:
        p.text(tx, base2, where, SIZE_NOTE, maxw=w - LINE_TITLE_DX - mw)


def _row_h(e: Event, day: date, tz: tzinfo, full: bool) -> int:
    """All-day and carried-over rows have no end time, so they stay one line."""
    if full and not _covers_day(e, day, tz) and not _is_continuation(e, day, tz):
        return FULL_ROW_H
    return LINE_H


def _agenda_week(p: _Page, data: AgendaData, days: list[date], per_day: list[list[Event]], tz: tzinfo) -> None:
    """Right column: the next six days. Allocation (every event is accounted for):

    1. every day shows min(1, n) compact rows;
    2. further compact rows are handed out round-robin, earliest day first;
    3. days switch to full rows (end time + location) in date order when that
       still fits: always when it costs no height, otherwise only once every
       event is shown.
    """
    rx, rw = AGENDA_RIGHT_X, AGENDA_RIGHT_W
    nx, nw = rx + DAY_LABEL_W, rw - DAY_LABEL_W
    n = len(days)

    def cost(i: int, shown: int, full: bool) -> int:
        rows = sum(_row_h(e, days[i], tz, full) for e in per_day[i][:shown])
        return max(DAY_LABEL_H, rows) + DAY_GAP

    budget = BOTTOM - AGENDA_TOP + DAY_GAP
    shown = [min(len(evs), 1) for evs in per_day]
    full = [False] * n

    def total() -> int:
        return sum(cost(i, shown[i], full[i]) for i in range(n))

    grew = True
    while grew:
        grew = False
        for i in range(n):
            if shown[i] < len(per_day[i]):
                shown[i] += 1
                if total() <= budget:
                    grew = True
                else:
                    shown[i] -= 1
    everything = all(shown[i] == len(per_day[i]) for i in range(n))
    for i in range(n):
        free = cost(i, shown[i], True) == cost(i, shown[i], False)
        if free or everything:
            full[i] = True
            if total() > budget:
                full[i] = False

    y = AGENDA_TOP
    for i, d in enumerate(days):
        evs = per_day[i]
        num = str(d.day)
        p.text(rx, y + LINE_BASE, num, DAY_NUMBER_SIZE, True)
        if i == 0:
            sub = "明天"
        elif d.day == 1:
            sub = f"{d.month}月"
        else:
            sub = _weekday_short(d)
        p.text(rx, y + DAY_SUB_BASE, sub, SIZE_NOTE)
        if not evs:
            p.text(nx + LINE_TITLE_DX, y + LINE_BASE, "沒有行程", SIZE_NOTE)
        ry = y
        for j, e in enumerate(evs[:shown[i]]):
            last = j == shown[i] - 1
            more = _more(len(evs) - shown[i]) if last and shown[i] < len(evs) else ""
            _list_row(p, nx, ry, nw, e, d, tz, full[i] and _row_h(e, d, tz, True) == FULL_ROW_H, more)
            ry += _row_h(e, d, tz, full[i])
        y += cost(i, shown[i], full[i])


def render_agenda(data: AgendaData, today: date, tz: tzinfo, background: Image.Image | None = None) -> Image.Image:
    """Today (Up Next + the rest of today) on the left, the next six days on the right."""
    p = _Page(background)
    days = [today + timedelta(days=i) for i in range(7)]
    per_day = [data.events_on(d, tz) for d in days]
    if not any(per_day):
        return _agenda_empty(p, data, today, tz)
    _agenda_header(p, data, today, tz)
    _agenda_today(p, data, today, tz, per_day[0])
    p.hairline_v(AGENDA_DIVIDER_X, AGENDA_TOP, BOTTOM)
    _agenda_week(p, data, days[1:], per_day[1:], tz)
    return p.img


# =============================================================================
# Day (日)
# =============================================================================

DAY_WEEKDAY_SIZE = 32  # 星期一, red bold, on HEADER_BASE
DAY_NUMERAL_SIZE = 180  # bold
DAY_NUMERAL_BASE = 232
DAY_MONTH_SIZE = 24  # 2026年10月 under the numeral
DAY_MONTH_BASE = 276
DAY_LIST_X = 326
DAY_LIST_W = W - MARGIN - DAY_LIST_X  # 446
DAY_LIST_TOP = AGENDA_TOP


def render_day(data: AgendaData, today: date, tz: tzinfo, background: Image.Image | None = None) -> Image.Image:
    """The big date and weekday on the left; all of today's events on the right (also those that have ended,
    so the page does not depend on the time of the sync)."""
    p = _Page(background)
    p.text(MARGIN, HEADER_BASE, _weekday_long(today), DAY_WEEKDAY_SIZE, True, RED)
    p.text(MARGIN, DAY_NUMERAL_BASE, str(today.day), DAY_NUMERAL_SIZE, True)
    p.text(MARGIN, DAY_MONTH_BASE, f"{today.year}年{today.month}月", DAY_MONTH_SIZE)
    sync = _sync_text(data, today, tz)
    if sync:
        p.text(W - MARGIN, HEADER_BASE, sync, SIZE_SYNC, anchor="rs")

    x, w, y = DAY_LIST_X, DAY_LIST_W, DAY_LIST_TOP
    events = data.events_on(today, tz)
    if events:
        allday, timed, _ = _split_day(events, today, tz, None)
        if allday:
            y = _allday_line(p, x, y, w, allday, today, tz) + 6
        _timed_list(p, x, y, w, BOTTOM, timed, today, tz)
        return p.img
    p.text(x, y + 34, "今天沒有行程", HERO_MESSAGE_SIZE, True)
    y += 56
    nxt = _next_event(data, today, tz)
    if nxt is None:
        p.text(x, y + 22, "近期沒有行程", SIZE_NOTE)
    elif y + 8 + SECTION_GAP + SECTION_H + CARD_H <= BOTTOM:
        _next_card(p, x, y + 8, w, nxt, today, tz)
    return p.img


# =============================================================================
# Month grid (月曆)
# =============================================================================

MG_X0, MG_X1 = MARGIN, W - MARGIN  # 7 columns of 106.3 px
MG_TITLE_SIZE = 28  # 2026年 regular + 10月 bold red
MG_DOW_BASE = 86
MG_TOP = 96
MG_BOTTOM = BOTTOM + 2
MG_DAY_CY = 18  # numeral centre below the row top
MG_TODAY_R = 16  # red disc behind today's numeral
MG_DOT_DY = 26  # dot row below the numeral centre
MG_TITLE_DY = 66  # baseline of the first short title below the row top; further ones 22 px apart
MG_TITLE_PITCH = 22
MG_TITLE_PAD = 6  # the title may use the cell width less this much on each side


def render_monthgrid(data: AgendaData, today: date, tz: tzinfo,
                     background: Image.Image | None = None) -> Image.Image:
    """The month containing ``today`` over the whole page. Only Sundays are red (holidays are events like any
    other). Each day has its event dots; where a row is tall enough (5 weeks or fewer) the first event's short
    title (as many events as fit, 4-week months) sits under the dots."""
    p = _Page(background)
    cw = (MG_X1 - MG_X0) / 7
    cxs = [MG_X0 + cw * (i + 0.5) for i in range(7)]
    x = MARGIN + p.text(MARGIN, HEADER_BASE, f"{today.year}年", MG_TITLE_SIZE)
    p.text(x, HEADER_BASE, f"{today.month}月", MG_TITLE_SIZE, True, RED)
    sync = _sync_text(data, today, tz)
    if sync:
        p.text(W - MARGIN, HEADER_BASE, sync, SIZE_SYNC, anchor="rs")
    for i, ch in enumerate("日一二三四五六"):
        p.text(cxs[i], MG_DOW_BASE, ch, MONTH_DOW_SIZE, fill=RED if i == 0 else INK, anchor="ms")

    weeks = calendar.Calendar(firstweekday=6).monthdatescalendar(today.year, today.month)
    rh = (MG_BOTTOM - MG_TOP) / len(weeks)
    lines = max(0, math.floor((rh - MG_TITLE_DY - 6) / MG_TITLE_PITCH) + 1)  # titles that fit in a row
    top, bottom = _font(MONTH_DAY_SIZE).getbbox("0", anchor="ls")[1::2]
    for r, week in enumerate(weeks):
        row = MG_TOP + rh * r
        cy = row + MG_DAY_CY
        base = cy - (top + bottom) / 2
        for c, d in enumerate(week):
            if d.month != today.month:
                continue
            cx = cxs[c]
            if d == today:
                p.disc(cx, cy, MG_TODAY_R, RED)
                p.text(cx, base, str(d.day), MONTH_DAY_SIZE, True, PAPER, anchor="ms")
            else:
                p.text(cx, base, str(d.day), MONTH_DAY_SIZE, False, RED if c == 0 else INK, anchor="ms")
            events = data.events_on(d, tz)
            _draw_dots(p, cx, round(cy + MG_DOT_DY), *_month_dots(events))
            for k, e in enumerate(events[:lines]):
                p.text(cx, row + MG_TITLE_DY + MG_TITLE_PITCH * k, _title(e.title), SIZE_NOTE, anchor="ms",
                       maxw=cw - 2 * MG_TITLE_PAD)
    return p.img


# =============================================================================
# To-do
# =============================================================================

TODO_TITLE_SIZE = 32  # 待辦事項, blue bold, on HEADER_BASE
TODO_COUNT_SIZE = 44  # open count, blue bold, right-aligned, on HEADER_BASE
TODO_SUMMARY_BASE = 86  # '1 項已逾期·1 項今天到期' (red / blue bold 18) and the sync stamp
TODO_TOP = 96
TODO_HEIGHT = BOTTOM - TODO_TOP  # 366
TODO_COL_W, TODO_GUTTER = 350, 44
TODO_FULL_W = W - 2 * MARGIN  # 744: single column

# Two-line rows: ring, title, then 'due · list · notes'.
# (ring radius, title size, detail size, pitch, title baseline dy, detail baseline dy)
TODO_ROW_LARGE = (13, 26, 20, 72, 30, 58)  # up to 5 rows per column
TODO_ROW_NORMAL = (11, 22, 18, 52, 24, 46)  # up to 7 rows per column

# Section mode (long lists): uniform 44 px slots, 8 per column, 2 columns.
TODO_SLOT_H = 44
TODO_SLOTS_PER_COL = TODO_HEIGHT // TODO_SLOT_H  # 8
TODO_SECTION_SIZE = 20


def _task_kind(t: Task, today: date) -> str:
    if t.due is None:
        return "undated"
    if t.due < today:
        return "overdue"
    return "today" if t.due == today else "later"


def _ring_colour(kind: str):
    return {"overdue": RED, "today": BLUE}.get(kind, INK)


def _overdue_label(t: Task, today: date) -> str:
    days = (today - t.due).days
    return "昨天" if days == 1 else f"逾期 {days} 天"


def _task_parts(t: Task, today: date) -> list[tuple[str, tuple, bool]]:
    """Second-line segments (text, colour, bold), joined with ' · '."""
    kind = _task_kind(t, today)
    parts: list[tuple[str, tuple, bool]] = []
    if kind == "overdue":
        parts.append((_overdue_label(t, today), RED, True))
        if (today - t.due).days > 1:
            parts.append((_md_year(t.due, today), INK, False))
    elif kind == "today":
        parts.append(("今天", BLUE, True))
    elif kind == "later":
        if (t.due - today).days == 1:
            parts.append(("明天", INK, False))
        else:
            parts.append((f"{_md_year(t.due, today)} {_weekday_short(t.due)}", INK, False))
    for extra in (t.list_name, t.notes):
        text = fonts.clean(extra or "")
        if text:
            parts.append((text, INK, False))
    return parts


def _parts_line(p: _Page, x: float, base: float, w: float, parts, size: int) -> None:
    """Draw segments left to right, separated by ' · '; the one that overflows gets '…'."""
    end = x + w
    for i, (text, colour, bold) in enumerate(parts):
        if i:
            if x + _width(SEP, size) >= end:
                return
            x += p.text(x, base, SEP, size)
        drawn = p.text(x, base, text, size, bold, colour, maxw=end - x)
        if drawn < _width(text, size, bold):
            return
        x += drawn


def _todo_row(p: _Page, x: int, y: int, w: int, t: Task, today: date, style, separator: bool) -> None:
    ring_r, title_size, detail_size, pitch, title_dy, detail_dy = style
    kind = _task_kind(t, today)
    ring_cy = y + title_dy - round(title_size * 0.38)  # centre of the CJK glyph box
    p.ring(x + ring_r, ring_cy, ring_r, _ring_colour(kind), 2)
    tx = x + 2 * ring_r + 12
    p.text(tx, y + title_dy, _title(t.title), title_size, maxw=x + w - tx)
    _parts_line(p, tx, y + detail_dy, x + w - tx, _task_parts(t, today), detail_size)
    if separator:
        p.hairline_h(tx, x + w, y + pitch - 1)


def _todo_list(p: _Page, tasks: list[Task], today: date) -> bool:
    """Flat list of two-line rows if it fits in one or two columns; returns False if not."""
    n = len(tasks)
    layouts = (
        (1, TODO_ROW_LARGE),
        (1, TODO_ROW_NORMAL),
        (2, TODO_ROW_LARGE),
        (2, TODO_ROW_NORMAL),
    )
    for cols, style in layouts:
        per_col = TODO_HEIGHT // style[3]
        if n <= per_col * cols:
            break
    else:
        return False
    rows = -(-n // cols)  # balanced columns, filled top to bottom
    w = TODO_FULL_W if cols == 1 else TODO_COL_W
    for i, t in enumerate(tasks):
        c, r = divmod(i, rows)
        x = MARGIN + c * (TODO_COL_W + TODO_GUTTER)
        last_in_col = r == rows - 1 or i == n - 1
        _todo_row(p, x, TODO_TOP + r * style[3], w, t, today, style, not last_in_col)
    return True


def _todo_sections(p: _Page, tasks: list[Task], today: date) -> None:
    """Long lists: 逾期 / 今天 / 之後 / 未排定 sections flowing through two columns.

    Every slot is 44 px (header, task row or '還有 N 項'); a header never ends
    a column, and a section that continues in the next column repeats its
    header there. Each non-empty section shows at least one row; then 逾期 and
    今天 grow round-robin until full; then 之後 and 未排定 round-robin.
    """
    groups = [("逾期", RED, "overdue"), ("今天", BLUE, "today"), ("之後", INK, "later"), ("未排定", INK, "undated")]
    sections = [(name, colour, [t for t in tasks if _task_kind(t, today) == kind])
                for name, colour, kind in groups]
    sections = [s for s in sections if s[2]]
    capacity = TODO_SLOTS_PER_COL * 2

    def flow(shown: list[int]) -> list | None:
        """Slot list for this allocation (None = blank slot), or None if it overflows."""
        slots: list = []
        for (name, colour, ts), k in zip(sections, shown):
            if len(slots) % TODO_SLOTS_PER_COL == TODO_SLOTS_PER_COL - 1:
                slots.append(None)  # a header never ends a column
            header = ("header", name, colour, len(ts))
            slots.append(header)
            body = [("task", t) for t in ts[:k]] + ([("more", len(ts) - k)] if k < len(ts) else [])
            for item in body:
                if len(slots) % TODO_SLOTS_PER_COL == 0:
                    slots.append(header)  # sticky header: repeat it where a section continues
                slots.append(item)
        return slots if len(slots) <= capacity else None

    shown = [1] * len(sections)
    while flow(shown) is None and len(sections) > 1:  # cannot happen with <= 4 sections
        sections.pop()
        shown.pop()
    for phase in (("逾期", "今天"), ("之後", "未排定")):
        idx = [i for i, s in enumerate(sections) if s[0] in phase]
        grew = True
        while grew:
            grew = False
            for i in idx:
                if shown[i] < len(sections[i][2]):
                    shown[i] += 1
                    if flow(shown) is None:
                        shown[i] -= 1
                    else:
                        grew = True

    slots = flow(shown)
    ring_r, title_size = 11, 22
    for s, item in enumerate(slots):
        if item is None:
            continue
        c, r = divmod(s, TODO_SLOTS_PER_COL)
        x = MARGIN + c * (TODO_COL_W + TODO_GUTTER)
        y = TODO_TOP + r * TODO_SLOT_H
        tx = x + 2 * ring_r + 12
        if item[0] == "header":
            _, name, colour, count = item
            p.text(x, y + 30, name, TODO_SECTION_SIZE, True, colour)
            p.text(x + TODO_COL_W, y + 30, str(count), TODO_SECTION_SIZE, True, colour, anchor="rs")
            p.hairline_h(x, x + TODO_COL_W, y + 38)
        elif item[0] == "more":
            p.text(tx, y + 28, _more(item[1]), SIZE_NOTE)
        else:
            t = item[1]
            kind = _task_kind(t, today)
            base = y + 30
            p.ring(x + ring_r, base - 8, ring_r, _ring_colour(kind), 2)
            if kind == "overdue":
                label, colour, bold = _overdue_label(t, today), RED, True
            elif kind == "later":
                label = "明天" if (t.due - today).days == 1 else _md_year(t.due, today)
                colour, bold = INK, False
            else:  # the section header already says 今天 / 未排定: show the list instead
                label, colour, bold = fonts.clean(t.list_name or ""), INK, False
            lw = p.text(x + TODO_COL_W, base, label, SIZE_NOTE, bold, colour, anchor="rs",
                        maxw=TODO_COL_W // 3) + 12 if label else 0
            p.text(tx, base, _title(t.title), title_size, maxw=x + TODO_COL_W - tx - lw)


def _todo_done(p: _Page) -> None:
    """Empty state: a blue check in a circle, as Reminders shows a finished list."""
    cx, cy, r = W // 2, 224, 32
    p.ring(cx, cy, r, BLUE, 3)
    p.line([(cx - 14, cy + 1), (cx - 4, cy + 11), (cx + 15, cy - 10)], BLUE, 4)
    p.text(cx, 304, "沒有待辦事項", 30, True, anchor="ms")
    p.text(cx, 338, "全部完成了", 20, anchor="ms")


def render_todo(data: AgendaData, today: date, tz: tzinfo, background: Image.Image | None = None) -> Image.Image:
    """Open tasks, Reminders style; overdue in red, due today in blue, both bold-labelled."""
    p = _Page(background)
    tasks = data.sorted_tasks()
    p.text(MARGIN, HEADER_BASE, "待辦事項", TODO_TITLE_SIZE, True, BLUE)
    p.text(W - MARGIN, HEADER_BASE, str(len(tasks)), TODO_COUNT_SIZE, True, BLUE, anchor="rs")

    overdue = sum(1 for t in tasks if _task_kind(t, today) == "overdue")
    due_today = sum(1 for t in tasks if _task_kind(t, today) == "today")
    parts = []
    if overdue:
        parts.append((f"{overdue} 項已逾期", RED, True))
    if due_today:
        parts.append((f"{due_today} 項今天到期", BLUE, True))
    if parts:
        _parts_line(p, MARGIN, TODO_SUMMARY_BASE, 500, parts, SIZE_NOTE)
    sync = _sync_text(data, today, tz)
    if sync:
        p.text(W - MARGIN, TODO_SUMMARY_BASE, sync, SIZE_SYNC, anchor="rs")

    if not tasks:
        _todo_done(p)
    elif not _todo_list(p, tasks, today):
        _todo_sections(p, tasks, today)
    return p.img


# =============================================================================
# Message board (留言板) and one big message (大字留言)
# =============================================================================

BOARD_TITLE_SIZE = 32  # 留言板, bold, on HEADER_BASE
BOARD_TOP = 84  # cards and the big message live in y BOARD_TOP..BOTTOM, x MARGIN..W - MARGIN
BOARD_GAP = 16
BOARD_MAX = 6  # notes on the board; the header says when there are more
#: notes on the board -> (columns, rows), filled left to right, top to bottom
BOARD_GRID = {1: (1, 1), 2: (2, 1), 3: (3, 1), 4: (2, 2), 5: (3, 2), 6: (3, 2)}
CARD_RADIUS = 12
CARD_PAD = 14
CARD_TEXT_SIZES = (44, 36, 30, 26, 22, 20)  # bold; the largest at which the whole note fits
CARD_TIME_SIZE = SIZE_NOTE  # '10/12 14:03', bottom-left in the card
CARD_TIME_GAP = 10  # between the last text line and the time
NOTE_PITCH = 1.25  # line pitch, times the text size

MESSAGE_TITLE_SIZE = 28  # 留言, red bold, on HEADER_BASE
MESSAGE_SIZES = (120, 96, 80, 64, 52, 44, 36, 30)  # bold; the largest at which the whole note fits

#: card text on each note colour (WCAG contrast): black on yellow 19.6, orange
#: 8.2 and green 15.3 (white on green would be 1.4); white on blue 8.6 and red 4.0
CARD_INK = {"yellow": INK, "orange": INK, "green": INK, "blue": PAPER, "red": PAPER}
UNDRAWABLE_NOTE = "（無法顯示的留言）"  # only characters the font lacks (e.g. emoji)


def _note_colour(note: Note) -> str:
    return note.color if note.color in CARD_INK else "yellow"


def _note_time(note: Note, tz: tzinfo) -> str:
    """'10/12 14:03': when the note was written, in ``tz``."""
    try:
        t = datetime.fromisoformat(note.at)
    except (TypeError, ValueError):
        return ""
    t = t.astimezone(tz) if t.tzinfo is not None else t
    return f"{t.month}/{t.day} {_hm(t)}"


def _note_paragraphs(note: Note) -> list[str]:
    """The note's lines (its own line breaks) as drawable text; never empty."""
    paras = [fonts.clean(line) for line in (note.text or "").split("\n")]
    return [line for line in paras if line] or [UNDRAWABLE_NOTE]


def _glyph_extent(size: int) -> tuple[int, int]:
    """(height above, depth below) the baseline of a bold CJK glyph at ``size``."""
    _, top, _, bottom = _font(size, True).getbbox("國", anchor="ls")
    return -top, bottom


def _flow(paras: list[str], font, width: float, max_lines: int) -> tuple[list[str], bool]:
    """Wrap paragraphs into at most ``max_lines`` lines; (lines, everything fitted).
    When something is left out, the last line ends with '…'."""
    lines: list[str] = []
    for para in paras:
        room = max_lines - len(lines)
        whole = _wrap(para, font, width, 10 ** 6)
        if len(whole) <= room:
            lines += whole
            continue
        if room > 0:
            lines += _wrap(para, font, width, room)
        else:
            lines[-1] = _fit(lines[-1] + ELLIPSIS, font, width)
        return lines, False
    return lines, True


def _orphaned(paras: list[str], font, width: float) -> bool:
    """Some paragraph wraps onto a last line of one character, perhaps with
    closing punctuation ('生日快' over '樂！')."""
    for para in paras:
        lines = _wrap(para, font, width, 10 ** 6)
        if len(lines) > 1 and len(lines[-1].rstrip("".join(_NO_LINE_START))) <= 1:
            return True
    return False


def _fit_note(paras: list[str], sizes: tuple[int, ...], width: float, height: float,
              orphans: bool = True) -> tuple[int, list[str]]:
    """(size, lines): the largest of ``sizes`` at which the whole text fits in
    ``width`` x ``height``, else the smallest with an ellipsis on the last line.
    With ``orphans`` False, a size at which a paragraph would end on a line of
    one character (see _orphaned) is passed over for the next one that fits
    without; if there is none, the largest that fits is used after all."""
    found: tuple[int, list[str]] | None = None
    for size in sizes:
        above, below = _glyph_extent(size)
        max_lines = max(1, int((height - above - below) // (size * NOTE_PITCH)) + 1)
        font = _font(size, True)
        lines, complete = _flow(paras, font, width, max_lines)
        if complete:
            found = found or (size, lines)
            if orphans or not _orphaned(paras, font, width):
                return size, lines
    return found or (size, lines)


def _balance(paras: list[str], size: int, width: float, lines: list[str]) -> list[str]:
    """The same number of lines at the narrowest width that still holds the
    whole text (no Latin word split), so a centred block has even lines
    instead of a long line over a short one."""
    font = _font(size, True)
    words = [t for para in paras for t in _TOKEN.findall(para) if not t.isspace()]
    lo, hi = min(width, max(font.getlength(t) for t in words)), width
    while hi - lo > 1:
        mid = (lo + hi) / 2
        if _flow(paras, font, mid, len(lines))[1]:
            hi = mid
        else:
            lo = mid
    return _flow(paras, font, hi, len(lines))[0]


def _notes_empty(p: _Page) -> None:
    """No notes yet: a blank sticky note and one calm message."""
    cx, cy, half = W // 2, 222, 34
    p.panel(cx - half, cy - half, cx + half - 1, cy + half - 1, "yellow", 10)
    for dy, w in ((-12, 36), (0, 36), (12, 22)):
        p.rect(cx - 18, cy + dy - 1, cx - 18 + w - 1, cy + dy + 1)
    p.text(cx, 304, "還沒有留言", 30, True, anchor="ms")
    p.text(cx, 338, "在 Paperhue 輸入留言，就會顯示在這裡", 20, anchor="ms")


def _board_card(p: _Page, x0: int, y0: int, x1: int, y1: int, note: Note, tz: tzinfo) -> None:
    """Sticky note in the box (inclusive): bold text from the top left, the time at the bottom."""
    name = _note_colour(note)
    ink = CARD_INK[name]
    p.panel(x0, y0, x1, y1, name, CARD_RADIUS)
    x, w = x0 + CARD_PAD, x1 + 1 - x0 - 2 * CARD_PAD
    time_base = y1 + 1 - CARD_PAD - 2  # '/' reaches 2 px below the baseline
    time_top = time_base + _font(CARD_TIME_SIZE).getbbox("0", anchor="ls")[1]
    top = y0 + CARD_PAD
    size, lines = _fit_note(_note_paragraphs(note), CARD_TEXT_SIZES, w, time_top - CARD_TIME_GAP - top,
                            orphans=False)
    base = top + _glyph_extent(size)[0]
    for i, line in enumerate(lines):
        p.text(x, base + i * size * NOTE_PITCH, line, size, True, ink, maxw=w)
    p.text(x, time_base, _note_time(note, tz), CARD_TIME_SIZE, False, ink, maxw=w)


def render_board(notes: list[Note], tz: tzinfo) -> Image.Image:
    """The newest notes (up to 6, newest first) as sticky notes."""
    p = _Page()
    p.text(MARGIN, HEADER_BASE, "留言板", BOARD_TITLE_SIZE, True)
    n = len(notes)
    if not n:
        _notes_empty(p)
        return p.img
    count = f"{n} 則" if n <= BOARD_MAX else f"最新 {BOARD_MAX} 則，共 {n} 則"
    p.text(W - MARGIN, HEADER_BASE, count, SIZE_NOTE, anchor="rs")
    shown = notes[:BOARD_MAX]
    cols, rows = BOARD_GRID[len(shown)]
    cw = (W - 2 * MARGIN - (cols - 1) * BOARD_GAP) / cols
    ch = (BOTTOM - BOARD_TOP - (rows - 1) * BOARD_GAP) / rows
    for i, note in enumerate(shown):
        r, c = divmod(i, cols)
        x0, y0 = MARGIN + c * (cw + BOARD_GAP), BOARD_TOP + r * (ch + BOARD_GAP)
        _board_card(p, round(x0), round(y0), round(x0 + cw) - 1, round(y0 + ch) - 1, note, tz)
    return p.img


def render_message(notes: list[Note], tz: tzinfo) -> Image.Image:
    """The newest note alone, centred, as large as it fits."""
    p = _Page()
    p.text(MARGIN, HEADER_BASE, "留言", MESSAGE_TITLE_SIZE, True, RED)
    if not notes:
        _notes_empty(p)
        return p.img
    note = notes[0]
    p.text(W - MARGIN, HEADER_BASE, _note_time(note, tz), SIZE_NOTE, anchor="rs")
    name = _note_colour(note)
    colour = RGB[name] if name in ("red", "blue") else INK  # yellow / orange / green are pale on white
    w, h = W - 2 * MARGIN, BOTTOM - BOARD_TOP
    paras = _note_paragraphs(note)
    size, lines = _fit_note(paras, MESSAGE_SIZES, w, h)
    if len(lines) > len(paras) and not lines[-1].endswith(ELLIPSIS):
        lines = _balance(paras, size, w, lines)
    above, below = _glyph_extent(size)
    pitch = size * NOTE_PITCH
    block = above + (len(lines) - 1) * pitch + below
    base = BOARD_TOP + (h - block) / 2 + above
    for i, line in enumerate(lines):
        p.text(W / 2, base + i * pitch, line, size, True, colour, anchor="ms", maxw=w)
    return p.img


# =============================================================================
# Cards (牌卡)
# =============================================================================

def _px(fraction: float, total: int) -> int:
    """A screen fraction in pixels, rounding halves up (the same in every implementation)."""
    return math.floor(fraction * total + 0.5)


def load_background(name: str, crop=None, folder=None, strength: float = 1.0) -> Image.Image:
    """The photo ``name`` in ``folder`` (default: the config folder's backgrounds/) as an 800x480 page background:
    cut to ``crop`` (None = centred, see shared/CROP.md) from the stored photo and dithered with Stucki at
    ``strength``. A photo takes a few seconds to dither, so keep the result. UlaniError if it cannot be read."""
    path = Path(folder or config.backgrounds_dir()) / name
    try:
        return to_indexed(fit(open_image(path), "cover", crop=crop), strength=strength).convert("RGB")
    except (OSError, SyntaxError, ValueError) as e:
        raise UlaniError(f"無法讀取背景圖 {name}：{e}") from None


def _card_background(p: _Page, bg: cards.Background, backgrounds, strength: float) -> None:
    if bg.image is None:
        p.rect(0, 0, W - 1, H - 1, RGB[bg.color])
        return
    p.img.paste(load_background(bg.image, bg.crop, backgrounds or cards.backgrounds_dir(), strength))


def _card_text(p: _Page, t: cards.TextBox) -> None:
    """One text box: bold, wrapped inside the box from its top, aligned; the outline stays inside the box too."""
    outline = _outline_radius(t.size) if t.outline else 0
    left, top = _px(t.box[0], W) + outline, _px(t.box[1], H) + outline
    right, bottom = _px(t.box[0] + t.box[2], W) - outline, _px(t.box[1] + t.box[3], H) - outline
    paras = [line for line in (fonts.clean(line) for line in t.text.split("\n")) if line]
    if not paras or right <= left:
        return
    above, below = _glyph_extent(t.size)
    pitch = t.size * NOTE_PITCH
    max_lines = max(1, int((bottom - top - above - below) // pitch) + 1)  # one line is always drawn
    lines, _ = _flow(paras, _font(t.size, True), right - left, max_lines)
    x, anchor = {"left": (left, "ls"), "center": ((left + right) // 2, "ms"), "right": (right, "rs")}[t.align]
    for i, line in enumerate(lines):
        p.text(x, top + above + math.floor(i * pitch + 0.5), line, t.size, True, RGB[t.color], anchor,
               maxw=right - left, outline=outline, outline_fill=RGB[t.outline_color])


def render_card(card: cards.Card, backgrounds=None, strength: float = 1.0) -> Image.Image:
    """A card: its background (a plain ink, or the photo cropped and dithered with Stucki at ``strength``; the
    file is looked up in ``backgrounds``, default the config folder's backgrounds/), then its text boxes in order.
    UlaniError if the background file cannot be read."""
    p = _Page()
    _card_background(p, card.background, backgrounds, strength)
    for t in card.texts:
        _card_text(p, t)
    return p.img


# =============================================================================
# Golden renders
# =============================================================================

RENDERERS = {"month": render_month, "agenda": render_agenda, "todo": render_todo, "day": render_day,
             "monthgrid": render_monthgrid}  # (data, today, tz[, background])
BOARD_RENDERERS = {"board": render_board, "message": render_message}  # (notes, tz)
CARD_RENDERERS = {"card": render_card}  # (card, folder with its background image)


def drawn_texts(render, *args) -> list[str]:
    """Every string ``render(*args)`` draws, in drawing order (exact checks of times, counts, labels)."""
    _Page.record = []
    try:
        render(*args)
        return _Page.record
    finally:
        _Page.record = None


def _golden_pages(obj: dict, folder: str) -> tuple[dict, tuple]:
    """(renderers, their arguments) for one fixture: calendar data, notes, or a card (its background
    image is looked up in ``folder``)."""
    import json

    if "texts" in obj:
        return CARD_RENDERERS, (cards.parse(obj), folder)

    tz = datetime.strptime(obj["utc_offset"].replace(":", ""), "%z").tzinfo
    if "notes" in obj:
        notes = [Note(n["id"], n["text"], n["at"], n.get("color", "yellow")) for n in obj["notes"]]
        return BOARD_RENDERERS, (notes, tz)
    args = (AgendaData.from_json(json.dumps(obj)), date.fromisoformat(obj["today"]), tz)
    if "background" in obj:  # the pages drawn on that photo (a file in the fixtures folder)
        args += (load_background(obj["background"]["image"], obj["background"].get("crop"), folder),)
    return RENDERERS, args


def write_golden(fixtures: str, out: str) -> list[str]:
    """Render every ``fixtures/*.json`` as ``out/<page>_<fixture>.png`` plus
    ``.txt`` (the drawn strings, one per line); the reference for tests and the
    Swift port. A fixture is AgendaData + "today" + "utc_offset" (calendar
    pages; with "background": {"image", "crop"} drawn on that photo), "notes" + "utc_offset" (board pages), or a card (shared/CARDS.md)."""
    import json
    import os

    os.makedirs(out, exist_ok=True)
    written = []
    for name in sorted(n for n in os.listdir(fixtures) if n.endswith(".json")):
        with open(os.path.join(fixtures, name), encoding="utf-8") as f:
            obj = json.load(f)
        renderers, args = _golden_pages(obj, fixtures)
        for page, render in renderers.items():
            path = os.path.join(out, f"{page}_{name[:-5]}.png")
            render(*args).save(path, optimize=True)
            with open(path[:-4] + ".txt", "w", encoding="utf-8", newline="\n") as f:
                f.write("\n".join(drawn_texts(render, *args)) + "\n")
            written.append(path)
    return written


if __name__ == "__main__":  # from the repo root: python -m ulani_epaper.layouts shared/layouts/board shared/layouts/board/golden
    import sys

    for written_path in write_golden(sys.argv[1], sys.argv[2]):
        print(written_path)
