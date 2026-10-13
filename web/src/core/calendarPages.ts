/**
 * The calendar pages: 本日＋月曆 (`month`), 本日行程＋一週行程 (`agenda`), 待辦 (`todo`), 日 (`day`)
 * and 月曆 (`monthgrid`), drawn as in shared/LAYOUTS.md. This is a port of `layouts.py` (the
 * reference: when they differ, Python is right) and draws the same strings in the same places; the
 * tests compare them with the goldens in shared/layouts/agenda/golden/*.txt.
 *
 * Nothing reads the clock: "now" is when the data was read (when that was today), "today" is given.
 * Times are wall ms and days are day numbers (core/agenda.ts), so no time zone appears here.
 */

import {
  accent,
  type AgendaData,
  type CalEvent,
  compare,
  DAY,
  dayNumber,
  dayOf,
  eventsOn,
  sortedTasks,
  type Task,
  weekday,
  ymd,
} from './agenda';
import { wrap } from './cardLayout';
import { Page, type Typeface } from './calendarDraw';
import type { CalendarKind } from './pages';
import type { ColourName } from './palette';
import { HEIGHT, WIDTH } from './protocol';

// --- Canvas and type scale -------------------------------------------------------------

const W = WIDTH;
const MARGIN = 28; // left and right page margin
const BOTTOM = HEIGHT - 18; // no ink below this line
const HEADER_BASE = 56; // baseline of every page's top line

const SIZE_SYNC = 16;
const SIZE_END_TIME = 16;
const SIZE_NOTE = 18; // secondary: times, locations, '還有 N 項', section labels
const SIZE_TITLE = 20; // event titles in rows

const SEP = '·'; // the font's U+00B7 is full-width, so no spaces around it
const WEEKDAYS = '一二三四五六日'; // indexed by weekday(): Monday = 0
const UNTITLED = '（無標題）';
const UNDRAWABLE = '（無法顯示的標題）'; // it has a title, but only of characters the font lacks

const ROW_TEXT_DX = 15; // text x in cards and the all-day line (after the 5 px bar or 10 px dot)
const DOT_R = 5;
const ALLDAY_H = 34;
const ALLDAY_BASE = 22;
const CARD_H = 56;
const CARD_BAR_W = 5;
const CARD_BASE1 = 20;
const CARD_BASE2 = 44;
const LINE_H = 28;
const LINE_BASE = 22;
const LINE_BAR_W = 4;
const LINE_TIME_W = 70; // bar x offset (fits "至01:00" at 18 px)
const LINE_TITLE_DX = 82;
const NOTE_H = 28; // '還有 N 項' on a line of its own
const NOTE_BASE = 21;
const SECTION_GAP = 10; // space above a '明天' / '下一個行程' label
const SECTION_H = 26;

// --- Dates and events ------------------------------------------------------------------

const two = (n: number): string => String(n).padStart(2, '0');

function hm(wall: number): string {
  const minutes = Math.floor((((wall % DAY) + DAY) % DAY) / 60_000);
  return `${two(Math.floor(minutes / 60))}:${two(minutes % 60)}`;
}

const md = (day: number): string => `${ymd(day).month}月${ymd(day).day}日`;
/** '10月15日', or '2027年3月1日' when the year differs from `ref`'s. */
const mdYear = (day: number, ref: number): string => (ymd(day).year === ymd(ref).year ? md(day) : `${ymd(day).year}年${md(day)}`);
const weekdayLong = (day: number): string => `星期${WEEKDAYS[weekday(day)]}`;
const weekdayShort = (day: number): string => `週${WEEKDAYS[weekday(day)]}`;
const more = (n: number): string => `還有 ${n} 項`;

/** An event or task title as drawable text (emoji dropped, never empty). */
function title(p: Page, text: string): string {
  if (!text.trim()) return UNTITLED;
  return p.clean(text) || UNDRAWABLE;
}

/** All-day, or a timed event that spans the whole of `day` (drawn like all-day). */
const coversDay = (e: CalEvent, day: number): boolean => e.allDay || (e.start <= day * DAY && e.end >= (day + 1) * DAY);

/** Not over yet at `now` (a zero-length event is pending until it starts). */
const pending = (e: CalEvent, now: number): boolean => e.end > now || (e.start === e.end && e.start >= now);

/** '第 2 天，共 3 天' for an event spanning several days, else ''. */
function spanNote(e: CalEvent, day: number): string {
  const first = dayOf(e.start);
  const last = e.end > e.start ? dayOf(e.end - 1) : first;
  const total = last - first + 1;
  return total <= 1 ? '' : `第 ${day - first + 1} 天，共 ${total} 天`;
}

/** Time column, line 1: 'HH:MM', '全天', or '至HH:MM' for a carried-over event. */
function startLabel(e: CalEvent, day: number): string {
  if (coversDay(e, day)) return '全天';
  return e.start < day * DAY ? `至${hm(e.end)}` : hm(e.start);
}

/** Time column, line 2: the end time, or the end date 'M/D' when a bare time would mislead; '' when there is none. */
function endLabel(e: CalEvent, day: number): string {
  if (coversDay(e, day) || e.start === e.end || e.start < day * DAY) return '';
  if (e.end <= (day + 1) * DAY) return hm(e.end);
  if (dayOf(e.end) === day + 1 && e.end % DAY < e.start % DAY) return hm(e.end);
  return `${ymd(dayOf(e.end)).month}/${ymd(dayOf(e.end)).day}`;
}

const isContinuation = (e: CalEvent, day: number): boolean => !coversDay(e, day) && e.start < day * DAY;

/** The time range as seen on `day`, with no words relative to the reader's today. */
function rangeText(e: CalEvent, day: number): string {
  if (coversDay(e, day)) {
    const note = spanNote(e, day);
    return note ? `全天${SEP}${note}` : '全天';
  }
  if (e.start === e.end) return hm(e.start);
  if (e.start < day * DAY) return `至 ${hm(e.end)}`;
  if (e.end <= (day + 1) * DAY) return `${hm(e.start)} – ${hm(e.end)}`;
  if (dayOf(e.end) === day + 1) return `${hm(e.start)} – 隔天 ${hm(e.end)}`;
  return `${hm(e.start)} – ${mdYear(dayOf(e.end), day)} ${hm(e.end)}`;
}

/** Second line of a card: the time range, then the location if there is one. */
function detail(p: Page, e: CalEvent, day: number): string {
  const where = p.clean(e.location);
  return rangeText(e, day) + (where ? SEP + where : '');
}

/** The sync time if it is on `today`, else the start of `today`. */
function nowOf(data: AgendaData, today: number): number {
  const f = data.fetchedAt;
  return f !== null && dayOf(f) === today ? f : today * DAY;
}

/** '更新於 10/12': the date only, never the time, so two syncs on a day with nothing changed give the same image. */
function syncText(data: AgendaData, today: number): string {
  if (data.fetchedAt === null) return '';
  const t = ymd(dayOf(data.fetchedAt));
  return t.year === ymd(today).year ? `更新於 ${t.month}/${t.day}` : `更新於 ${t.year}/${t.month}/${t.day}`;
}

function drawSync(p: Page, data: AgendaData, today: number, base = HEADER_BASE): void {
  const sync = syncText(data, today);
  if (sync) p.text(W - MARGIN, base, sync, SIZE_SYNC, { anchor: 'rs' });
}

/** (all-day-like events, pending timed events, number of ended timed events). */
function splitDay(events: CalEvent[], day: number, now: number | null): [CalEvent[], CalEvent[], number] {
  const allday = events.filter((e) => coversDay(e, day));
  const timed = events.filter((e) => !coversDay(e, day));
  const open = now === null ? timed : timed.filter((e) => pending(e, now));
  return [allday, open, timed.length - open.length];
}

/** The first event that starts on a day after `after`. */
function nextEvent(data: AgendaData, after: number): CalEvent | undefined {
  const from = (after + 1) * DAY;
  return data.events
    .filter((e) => e.start >= from)
    .sort((a, b) => a.start - b.start || Number(!a.allDay) - Number(!b.allDay) || compare(a.title, b.title))[0];
}

// --- Shared rows -------------------------------------------------------------------------

/** All of a day's all-day events on one line; returns the new y. */
function alldayLine(p: Page, x: number, y: number, w: number, events: CalEvent[], day: number): number {
  const base = y + ALLDAY_BASE;
  const cy = base - 8; // dot centre at the middle of the CJK glyphs
  const titles = events.map((e) => title(p, e.title));
  const names = events.map((e) => accent(e.color));
  const n = events.length;
  const gap = 16; // between items
  if (n === 1) {
    p.dot(x + DOT_R, cy, DOT_R, names[0] as ColourName);
    const tw = p.text(x + ROW_TEXT_DX, base, titles[0] as string, SIZE_TITLE, { bold: true, maxw: w - ROW_TEXT_DX });
    const note = spanNote(events[0] as CalEvent, day);
    if (note && ROW_TEXT_DX + tw + 12 + p.width(note, SIZE_NOTE) <= w) p.text(x + ROW_TEXT_DX + tw + 12, base, note, SIZE_NOTE);
    return y + ALLDAY_H;
  }
  const itemW = titles.map((t) => ROW_TEXT_DX + p.width(t, SIZE_TITLE, true));
  const plusW = (rest: number): number => (rest ? gap + p.width(`+${rest}`, SIZE_NOTE) : 0);
  const sum = (k: number): number => itemW.slice(0, k).reduce((a, b) => a + b, 0);
  let k = 1; // at least one item (truncated if needed)
  while (k < n && sum(k + 1) + gap * k + plusW(n - k - 1) <= w) k++;
  let cx = x;
  for (let i = 0; i < k; i++) {
    p.dot(cx + DOT_R, cy, DOT_R, names[i] as ColourName);
    const room = w - (cx - x) - ROW_TEXT_DX - (i === k - 1 ? plusW(n - k) : 0);
    const tw = p.text(cx + ROW_TEXT_DX, base, titles[i] as string, SIZE_TITLE, { bold: true, maxw: room });
    cx += ROW_TEXT_DX + tw + gap;
  }
  if (k < n) p.text(cx, base, `+${n - k}`, SIZE_NOTE);
  return y + ALLDAY_H;
}

/** Two-line widget row: colour bar, bold title, 'time range · location'. */
function card(p: Page, x: number, y: number, w: number, e: CalEvent, day: number): void {
  p.bar(x, y + 4, y + CARD_H - 11, accent(e.color), CARD_BAR_W);
  p.text(x + ROW_TEXT_DX, y + CARD_BASE1, title(p, e.title), SIZE_TITLE, { bold: true, maxw: w - ROW_TEXT_DX });
  p.text(x + ROW_TEXT_DX, y + CARD_BASE2, detail(p, e, day), SIZE_NOTE, { maxw: w - ROW_TEXT_DX });
}

/** One-line row: start time, colour bar, title, optional right-aligned '還有 N 項'. */
function lineRow(p: Page, x: number, y: number, w: number, e: CalEvent, day: number, moreText = '', bold = false): void {
  const base = y + LINE_BASE;
  p.text(x, base, startLabel(e, day), SIZE_NOTE);
  p.bar(x + LINE_TIME_W, y + 5, y + LINE_H - 4, accent(e.color), LINE_BAR_W);
  const mw = moreText ? p.text(x + w, base, moreText, SIZE_NOTE, { anchor: 'rs' }) + 12 : 0;
  p.text(x + LINE_TITLE_DX, base, title(p, e.title), SIZE_TITLE, { bold, maxw: w - LINE_TITLE_DX - mw });
}

function note(p: Page, x: number, y: number, w: number, text: string): number {
  p.text(x, y + NOTE_BASE, text, SIZE_NOTE, { maxw: w });
  return y + NOTE_H;
}

/** Timed events as cards if all fit, else one-line rows, else rows and '還有 N 項'; returns (new y, x of a following note). */
function timedList(p: Page, x: number, y: number, w: number, bottom: number, events: CalEvent[], day: number): [number, number] {
  const n = events.length;
  if (n === 0) return [y, x + ROW_TEXT_DX];
  const avail = bottom - y;
  if (n * CARD_H <= avail) {
    for (const e of events) {
      card(p, x, y, w, e, day);
      y += CARD_H;
    }
    return [y, x + ROW_TEXT_DX];
  }
  const k = n * LINE_H <= avail ? n : Math.max(0, Math.floor((avail - NOTE_H) / LINE_H));
  for (const e of events.slice(0, k)) {
    lineRow(p, x, y, w, e, day, '', true);
    y += LINE_H;
  }
  if (k < n && y + NOTE_H <= bottom) y = note(p, x, y, w, more(n - k));
  return [y, x];
}

function sectionLabel(p: Page, x: number, y: number, text: string, fill: ColourName = 'black'): number {
  p.text(x, y + SECTION_GAP + 18, text, SIZE_NOTE, { bold: true, fill });
  return y + SECTION_GAP + SECTION_H;
}

/** The '下一個行程' block: a label, then a card whose second line names the day. */
function nextCard(p: Page, x: number, y: number, w: number, e: CalEvent, today: number): number {
  y = sectionLabel(p, x, y, '下一個行程');
  const d = dayOf(e.start);
  const dayName = d === today + 1 ? '明天' : `${mdYear(d, today)} ${weekdayShort(d)}`;
  const where = p.clean(e.location);
  const line = `${dayName} ${startLabel(e, d)}${where ? SEP + where : ''}`;
  p.bar(x, y + 4, y + CARD_H - 11, accent(e.color), CARD_BAR_W);
  p.text(x + ROW_TEXT_DX, y + CARD_BASE1, title(p, e.title), SIZE_TITLE, { bold: true, maxw: w - ROW_TEXT_DX });
  p.text(x + ROW_TEXT_DX, y + CARD_BASE2, line, SIZE_NOTE, { maxw: w - ROW_TEXT_DX });
  return y + CARD_H;
}

// --- Months ------------------------------------------------------------------------------

/** The weeks (Sunday first) of the month, as day numbers; days outside the month are included. */
function monthWeeks(day: number): number[][] {
  const { year, month } = ymd(day);
  const first = dayNumber(year, month, 1);
  const lead = (weekday(first) + 1) % 7; // days of the previous month in the first week
  const length = dayNumber(month === 12 ? year + 1 : year, (month % 12) + 1, 1) - first;
  return Array.from({ length: Math.ceil((lead + length) / 7) }, (_, w) => Array.from({ length: 7 }, (_, c) => first - lead + 7 * w + c));
}

const DIGIT_MID = -8; // the "0" of the 22 px numerals reaches 16 px above the baseline (Pillow's bbox): centre -8

/** Up to 4 dots: each calendar colour once first, then repeats to show load, grouped by colour; and whether a '+' follows. */
function monthDots(events: CalEvent[]): [ColourName[], boolean] {
  const seq = events.map((e) => accent(e.color));
  const distinct = [...new Set(seq)];
  const extra = [...seq];
  for (const name of distinct) extra.splice(extra.indexOf(name), 1);
  const dots = [...distinct, ...extra].slice(0, 4).sort((a, b) => distinct.indexOf(a) - distinct.indexOf(b));
  return [dots, events.length > 4];
}

const DOT_PITCH = 12; // 10 px dots, 2 px apart
const PLUS = 9;

/** The day's dots (and the '+') centred on `cx`, on row `dy`. */
function drawDots(p: Page, cx: number, dy: number, dots: ColourName[], plus: boolean): void {
  if (dots.length === 0) return;
  let group = DOT_PITCH * dots.length - (DOT_PITCH - 2 * DOT_R);
  if (plus) group += 4 + PLUS;
  const gx = Math.round(cx - group / 2);
  dots.forEach((name, j) => p.dot(gx + DOT_R + DOT_PITCH * j, dy, DOT_R, name));
  if (plus) p.plus(gx + group - PLUS, dy, PLUS);
}

const MONTH_DAY_SIZE = 22;
const MONTH_DOW_SIZE = 18;
const MONTH_TITLE_SIZE = 28;

function monthPanel(p: Page, data: AgendaData, today: number): void {
  const x = MARGIN;
  const w = 262;
  p.text(x, HEADER_BASE, weekdayLong(today), 26, { bold: true, fill: 'red' });
  p.text(x, 168, String(ymd(today).day), 128, { bold: true });

  let y = 196;
  const events = eventsOn(data, today);
  const [allday, open, ended] = splitDay(events, today, nowOf(data, today));
  if (events.length === 0) {
    p.text(x, y + 24, '今天沒有行程', 22, { bold: true });
    y += 34;
  } else {
    if (allday.length) y = alldayLine(p, x, y, w, allday, today);
    if (open.length === 0 && ended) {
      p.text(x, y + 24, '今天沒有其他行程', 22, { bold: true });
      y += 34;
    }
    let noteX: number;
    [y, noteX] = timedList(p, x, y, w, BOTTOM - (ended ? NOTE_H : 0), open, today);
    if (ended) y = note(p, noteX, y, w, `稍早已結束 ${ended} 項`);
  }

  // Like the Apple widget: if today leaves room, continue with tomorrow.
  const tomorrow = today + 1;
  const tEvents = eventsOn(data, tomorrow);
  if (tEvents.length) {
    const [tAllday, tTimed] = splitDay(tEvents, tomorrow, null);
    const need = SECTION_GAP + SECTION_H + (tAllday.length ? ALLDAY_H : 0) + (tTimed.length ? LINE_H : 0);
    if (y + need <= BOTTOM) {
      y = sectionLabel(p, x, y, '明天');
      if (tAllday.length) y = alldayLine(p, x, y, w, tAllday, tomorrow);
      timedList(p, x, y, w, BOTTOM, tTimed, tomorrow);
    }
    return;
  }
  if (events.length) return;
  // Nothing today or tomorrow: name the next event instead of an empty panel.
  const next = nextEvent(data, today);
  if (next === undefined) p.text(x, y + 22, '近期沒有行程', SIZE_NOTE); // the data covers only weeks ahead
  else nextCard(p, x, y, w, next, today);
}

function monthGrid(p: Page, data: AgendaData, today: number): void {
  const x0 = 326;
  const x1 = W - MARGIN + 6;
  const cw = (x1 - x0) / 7;
  const cxs = Array.from({ length: 7 }, (_, i) => x0 + cw * (i + 0.5));
  const { year, month } = ymd(today);

  // Title "2026年10月": year regular black, month bold red (zh-TW Calendar order).
  let tx = (cxs[0] as number) - 9;
  tx += p.text(tx, HEADER_BASE, `${year}年`, MONTH_TITLE_SIZE);
  p.text(tx, HEADER_BASE, `${month}月`, MONTH_TITLE_SIZE, { bold: true, fill: 'red' });
  drawSync(p, data, today);

  [...'日一二三四五六'].forEach((ch, i) => p.text(cxs[i] as number, 98, ch, MONTH_DOW_SIZE, { anchor: 'ms' }));

  const weeks = monthWeeks(today);
  const rh = Math.min(84, (BOTTOM + 2 - 110) / weeks.length);
  weeks.forEach((week, r) => {
    const cy = 110 + rh * r + 22;
    const base = cy - DIGIT_MID;
    week.forEach((d, c) => {
      if (ymd(d).month !== month) return; // days outside the month stay blank, as on iPhone
      const cx = cxs[c] as number;
      if (d === today) {
        p.disc(cx, cy, 19, 'red');
        p.text(cx, base, String(ymd(d).day), MONTH_DAY_SIZE, { bold: true, fill: 'white', anchor: 'ms' });
      } else {
        p.text(cx, base, String(ymd(d).day), MONTH_DAY_SIZE, { anchor: 'ms' });
      }
      drawDots(p, cx, Math.round(cy + 28), ...monthDots(eventsOn(data, d)));
    });
  });
}

/** 本日＋月曆: today on the left, the month on the right. */
function renderMonth(p: Page, data: AgendaData, today: number): void {
  monthPanel(p, data, today);
  monthGrid(p, data, today);
}

// --- Agenda ------------------------------------------------------------------------------

const AGENDA_TOP = 84;
const AGENDA_LEFT_W = 326;
const AGENDA_RIGHT_X = 404;
const AGENDA_RIGHT_W = W - MARGIN - AGENDA_RIGHT_X; // 368
const HERO_TITLE_SIZE = 40;
const HERO_TEXT_DX = 22;
const DAY_LABEL_W = 54; // day number column of the six-day list
const DAY_LABEL_H = 50; // number + 明天 / 週三 / 11月
const DAY_GAP = 6;
const FULL_ROW_H = 50; // list row with end time / location on a second line
const FULL_BASE2 = 44;

function agendaHeader(p: Page, data: AgendaData, today: number): void {
  let x = MARGIN;
  x += p.text(x, HEADER_BASE, weekdayLong(today), 28, { bold: true, fill: 'red' }) + 12;
  const last = today + 6;
  p.text(x, HEADER_BASE, ymd(last).year === ymd(today).year ? md(today) : `${ymd(today).year}年${md(today)}`, 28, { bold: true });
  drawSync(p, data, today);
}

/** Nothing all week: a Calendar-icon date and one calm message. */
function agendaEmpty(p: Page, data: AgendaData, today: number): void {
  const cx = W / 2;
  p.text(cx, 100, weekdayLong(today), 30, { bold: true, fill: 'red', anchor: 'ms' });
  p.text(cx, 232, String(ymd(today).day), 128, { bold: true, anchor: 'ms' });
  p.text(cx, 274, `${ymd(today).year}年${md(today)}`, 22, { anchor: 'ms' });
  p.hairlineH(cx - 150, cx + 150, 298);
  p.text(cx, 346, '今天沒有行程', 30, { bold: true, anchor: 'ms' });
  p.text(cx, 380, '接下來 6 天也沒有行程', 20, { anchor: 'ms' });
  drawSync(p, data, today);
}

/** Left column: all-day line, Up Next hero, the rest of today, ended count. */
function agendaToday(p: Page, data: AgendaData, today: number, events: CalEvent[]): void {
  const x = MARGIN;
  const w = AGENDA_LEFT_W;
  const now = nowOf(data, today);
  const [allday, open, endedAtStart] = splitDay(events, today, now);
  let ended = endedAtStart;
  let y = AGENDA_TOP;
  if (allday.length) y = alldayLine(p, x, y, w, allday, today) + 6;

  const hero = open[0];
  if (hero !== undefined) {
    p.text(x, y + 18, hero.start <= now && now < hero.end ? '進行中' : '接下來', 18, { bold: true, fill: 'red' });
    y += 28;
    const y0 = y;
    for (const line of wrap(title(p, hero.title), w - HERO_TEXT_DX, 2, (t) => p.width(t, HERO_TITLE_SIZE, true))) {
      p.text(x + HERO_TEXT_DX, y + 42, line, HERO_TITLE_SIZE, { bold: true });
      y += 52;
    }
    p.text(x + HERO_TEXT_DX, y + 28, rangeText(hero, today), 26, { maxw: w - HERO_TEXT_DX });
    y += 36;
    const where = p.clean(hero.location);
    if (where) {
      p.text(x + HERO_TEXT_DX, y + 24, where, 20, { maxw: w - HERO_TEXT_DX });
      y += 32;
    }
    p.bar(x, y0 + 10, y - 6, accent(hero.color), 7);
    y += 14;
  } else {
    p.text(x, y + 34, events.length === 0 ? '今天沒有行程' : '今天沒有其他行程', 30, { bold: true });
    y += 56;
    if (ended) {
      y = note(p, x, y, w, `稍早已結束 ${ended} 項`);
      ended = 0;
    }
    // Answer "what's next" even when today is done (Apple's Up Next shows tomorrow).
    const next = nextEvent(data, today);
    if (next !== undefined && y + SECTION_GAP + SECTION_H + CARD_H <= BOTTOM) y = nextCard(p, x, y + 8, w, next, today);
  }

  const rest = open.slice(1);
  const reserve = ended ? NOTE_H : 0;
  let noteX = x;
  if (rest.length && y + SECTION_H + Math.min(rest.length, 1) * LINE_H + reserve <= BOTTOM) {
    p.text(x, y + 18, '今天稍後', SIZE_NOTE, { bold: true });
    [y, noteX] = timedList(p, x, y + SECTION_H, w, BOTTOM - reserve, rest, today);
  } else if (rest.length) {
    y = note(p, x, y, w, more(rest.length));
  }
  if (ended && y + NOTE_H <= BOTTOM) note(p, noteX, y, w, `稍早已結束 ${ended} 項`);
}

/** Six-day list row. Compact: start | bar | title. Full adds the end time under the start and the location under the title. */
function listRow(p: Page, x: number, y: number, w: number, e: CalEvent, day: number, full: boolean, moreText = ''): void {
  if (!full) {
    lineRow(p, x, y, w, e, day, moreText);
    return;
  }
  const base1 = y + LINE_BASE;
  const base2 = y + FULL_BASE2;
  p.text(x, base1, startLabel(e, day), SIZE_NOTE);
  p.text(x, base2, endLabel(e, day), SIZE_END_TIME);
  p.bar(x + LINE_TIME_W, y + 5, y + FULL_ROW_H - 6, accent(e.color), LINE_BAR_W);
  const tx = x + LINE_TITLE_DX;
  p.text(tx, base1, title(p, e.title), SIZE_TITLE, { maxw: w - LINE_TITLE_DX });
  const mw = moreText ? p.text(x + w, base2, moreText, SIZE_NOTE, { anchor: 'rs' }) + 12 : 0;
  const where = p.clean(e.location);
  if (where) p.text(tx, base2, where, SIZE_NOTE, { maxw: w - LINE_TITLE_DX - mw });
}

/** All-day and carried-over rows have no end time, so they stay one line. */
function rowH(e: CalEvent, day: number, full: boolean): number {
  return full && !coversDay(e, day) && !isContinuation(e, day) ? FULL_ROW_H : LINE_H;
}

/**
 * Right column: the next six days. Every day shows one compact row; more rows are handed out round-robin,
 * earliest day first; then days switch to full rows (end time and location) in date order when that costs no
 * height, or once every event is shown.
 */
function agendaWeek(p: Page, days: number[], perDay: CalEvent[][]): void {
  const rx = AGENDA_RIGHT_X;
  const nx = rx + DAY_LABEL_W;
  const nw = AGENDA_RIGHT_W - DAY_LABEL_W;
  const n = days.length;
  const evs = (i: number): CalEvent[] => perDay[i] as CalEvent[];

  const cost = (i: number, shown: number, full: boolean): number =>
    Math.max(DAY_LABEL_H, evs(i).slice(0, shown).reduce((sum, e) => sum + rowH(e, days[i] as number, full), 0)) + DAY_GAP;

  const budget = BOTTOM - AGENDA_TOP + DAY_GAP;
  const shown = perDay.map((list) => Math.min(list.length, 1));
  const full = new Array<boolean>(n).fill(false);
  const total = (): number => shown.reduce((sum, s, i) => sum + cost(i, s, full[i] as boolean), 0);

  for (let grew = true; grew; ) {
    grew = false;
    for (let i = 0; i < n; i++) {
      if ((shown[i] as number) < evs(i).length) {
        (shown[i] as number)++;
        if (total() <= budget) grew = true;
        else (shown[i] as number)--;
      }
    }
  }
  const everything = shown.every((s, i) => s === evs(i).length);
  for (let i = 0; i < n; i++) {
    const free = cost(i, shown[i] as number, true) === cost(i, shown[i] as number, false);
    if (free || everything) {
      full[i] = true;
      if (total() > budget) full[i] = false;
    }
  }

  let y = AGENDA_TOP;
  days.forEach((d, i) => {
    const list = evs(i);
    p.text(rx, y + LINE_BASE, String(ymd(d).day), 26, { bold: true });
    p.text(rx, y + 44, i === 0 ? '明天' : ymd(d).day === 1 ? `${ymd(d).month}月` : weekdayShort(d), SIZE_NOTE);
    if (list.length === 0) p.text(nx + LINE_TITLE_DX, y + LINE_BASE, '沒有行程', SIZE_NOTE);
    let ry = y;
    list.slice(0, shown[i]).forEach((e, j) => {
      const last = j === (shown[i] as number) - 1;
      const left = last && (shown[i] as number) < list.length ? more(list.length - (shown[i] as number)) : '';
      listRow(p, nx, ry, nw, e, d, (full[i] as boolean) && rowH(e, d, true) === FULL_ROW_H, left);
      ry += rowH(e, d, full[i] as boolean);
    });
    y += cost(i, shown[i] as number, full[i] as boolean);
  });
}

function renderAgenda(p: Page, data: AgendaData, today: number): void {
  const days = Array.from({ length: 7 }, (_, i) => today + i);
  const perDay = days.map((d) => eventsOn(data, d));
  if (!perDay.some((list) => list.length)) {
    agendaEmpty(p, data, today);
    return;
  }
  agendaHeader(p, data, today);
  agendaToday(p, data, today, perDay[0] as CalEvent[]);
  p.hairlineV(380, AGENDA_TOP, BOTTOM);
  agendaWeek(p, days.slice(1), perDay.slice(1));
}

// --- Day ---------------------------------------------------------------------------------

/** 日: the big date and weekday on the left; all of today's events on the right (also those that ended). */
function renderDay(p: Page, data: AgendaData, today: number): void {
  p.text(MARGIN, HEADER_BASE, weekdayLong(today), 32, { bold: true, fill: 'red' });
  p.text(MARGIN, 232, String(ymd(today).day), 180, { bold: true });
  p.text(MARGIN, 276, `${ymd(today).year}年${ymd(today).month}月`, 24);
  drawSync(p, data, today);

  const x = 326;
  const w = W - MARGIN - x;
  let y = AGENDA_TOP;
  const events = eventsOn(data, today);
  if (events.length) {
    const [allday, timed] = splitDay(events, today, null);
    if (allday.length) y = alldayLine(p, x, y, w, allday, today) + 6;
    timedList(p, x, y, w, BOTTOM, timed, today);
    return;
  }
  p.text(x, y + 34, '今天沒有行程', 30, { bold: true });
  y += 56;
  const next = nextEvent(data, today);
  if (next === undefined) p.text(x, y + 22, '近期沒有行程', SIZE_NOTE);
  else if (y + 8 + SECTION_GAP + SECTION_H + CARD_H <= BOTTOM) nextCard(p, x, y + 8, w, next, today);
}

// --- Month grid --------------------------------------------------------------------------

/** 月曆: the month over the whole page; only Sundays are red; short titles where a row is tall enough. */
function renderMonthGrid(p: Page, data: AgendaData, today: number): void {
  const x0 = MARGIN;
  const cw = (W - MARGIN - x0) / 7;
  const cxs = Array.from({ length: 7 }, (_, i) => x0 + cw * (i + 0.5));
  const { year, month } = ymd(today);
  const x = MARGIN + p.text(MARGIN, HEADER_BASE, `${year}年`, 28);
  p.text(x, HEADER_BASE, `${month}月`, 28, { bold: true, fill: 'red' });
  drawSync(p, data, today);
  [...'日一二三四五六'].forEach((ch, i) => p.text(cxs[i] as number, 86, ch, MONTH_DOW_SIZE, { anchor: 'ms', fill: i === 0 ? 'red' : 'black' }));

  const weeks = monthWeeks(today);
  const rh = (BOTTOM + 2 - 96) / weeks.length;
  const lines = Math.max(0, Math.floor((rh - 66 - 6) / 22) + 1); // titles that fit in a row
  weeks.forEach((week, r) => {
    const row = 96 + rh * r;
    const cy = row + 18;
    const base = cy - DIGIT_MID;
    week.forEach((d, c) => {
      if (ymd(d).month !== month) return;
      const cx = cxs[c] as number;
      if (d === today) {
        p.disc(cx, cy, 16, 'red');
        p.text(cx, base, String(ymd(d).day), MONTH_DAY_SIZE, { bold: true, fill: 'white', anchor: 'ms' });
      } else {
        p.text(cx, base, String(ymd(d).day), MONTH_DAY_SIZE, { fill: c === 0 ? 'red' : 'black', anchor: 'ms' });
      }
      const events = eventsOn(data, d);
      drawDots(p, cx, Math.round(cy + 26), ...monthDots(events));
      events.slice(0, lines).forEach((e, k) => p.text(cx, row + 66 + 22 * k, title(p, e.title), SIZE_NOTE, { anchor: 'ms', maxw: cw - 12 }));
    });
  });
}

// --- To-do -------------------------------------------------------------------------------

const TODO_TOP = 96;
const TODO_HEIGHT = BOTTOM - TODO_TOP; // 366
const TODO_COL_W = 350;
const TODO_GUTTER = 44;
const TODO_FULL_W = W - 2 * MARGIN; // 744: single column
const TODO_SUMMARY_BASE = 86;

/** (ring radius, title size, detail size, pitch, title baseline dy, detail baseline dy) */
type RowStyle = readonly [number, number, number, number, number, number];
const ROW_LARGE: RowStyle = [13, 26, 20, 72, 30, 58]; // up to 5 rows per column
const ROW_NORMAL: RowStyle = [11, 22, 18, 52, 24, 46]; // up to 7 rows per column

const SLOT_H = 44; // sections: uniform slots, 8 per column, 2 columns
const SLOTS_PER_COL = Math.floor(TODO_HEIGHT / SLOT_H);

type Kind = 'overdue' | 'today' | 'later' | 'undated';

function taskKind(t: Task, today: number): Kind {
  if (t.due === null) return 'undated';
  return t.due < today ? 'overdue' : t.due === today ? 'today' : 'later';
}

const ringColour = (kind: Kind): ColourName => (kind === 'overdue' ? 'red' : kind === 'today' ? 'blue' : 'black');

function overdueLabel(t: Task, today: number): string {
  const days = today - (t.due as number);
  return days === 1 ? '昨天' : `逾期 ${days} 天`;
}

interface Part {
  text: string;
  colour: ColourName;
  bold: boolean;
}

/** Second-line segments of a task, joined with '·'. */
function taskParts(p: Page, t: Task, today: number): Part[] {
  const kind = taskKind(t, today);
  const parts: Part[] = [];
  if (kind === 'overdue') {
    parts.push({ text: overdueLabel(t, today), colour: 'red', bold: true });
    if (today - (t.due as number) > 1) parts.push({ text: mdYear(t.due as number, today), colour: 'black', bold: false });
  } else if (kind === 'today') {
    parts.push({ text: '今天', colour: 'blue', bold: true });
  } else if (kind === 'later') {
    const due = t.due as number;
    parts.push({ text: due - today === 1 ? '明天' : `${mdYear(due, today)} ${weekdayShort(due)}`, colour: 'black', bold: false });
  }
  for (const extra of [t.listName, t.notes]) {
    const text = p.clean(extra);
    if (text) parts.push({ text, colour: 'black', bold: false });
  }
  return parts;
}

/** Draw segments left to right, separated by '·'; the one that overflows gets '…' and drawing stops. */
function partsLine(p: Page, x: number, base: number, w: number, parts: Part[], size: number): void {
  const end = x + w;
  for (const [i, part] of parts.entries()) {
    if (i) {
      if (x + p.width(SEP, size) >= end) return;
      x += p.text(x, base, SEP, size);
    }
    const drawn = p.text(x, base, part.text, size, { bold: part.bold, fill: part.colour, maxw: end - x });
    if (drawn < p.width(part.text, size, part.bold)) return;
    x += drawn;
  }
}

function todoRow(p: Page, x: number, y: number, w: number, t: Task, today: number, style: RowStyle, separator: boolean): void {
  const [ringR, titleSize, detailSize, pitch, titleDy, detailDy] = style;
  const kind = taskKind(t, today);
  p.ring(x + ringR, y + titleDy - Math.round(titleSize * 0.38), ringR, ringColour(kind), 2); // centre of the CJK glyph box
  const tx = x + 2 * ringR + 12;
  p.text(tx, y + titleDy, title(p, t.title), titleSize, { maxw: x + w - tx });
  partsLine(p, tx, y + detailDy, x + w - tx, taskParts(p, t, today), detailSize);
  if (separator) p.hairlineH(tx, x + w, y + pitch - 1);
}

/** The flat list of two-line rows, if it fits in one or two columns; false if not. */
function todoList(p: Page, tasks: Task[], today: number): boolean {
  const n = tasks.length;
  const layouts: [number, RowStyle][] = [
    [1, ROW_LARGE],
    [1, ROW_NORMAL],
    [2, ROW_LARGE],
    [2, ROW_NORMAL],
  ];
  const found = layouts.find(([cols, style]) => n <= Math.floor(TODO_HEIGHT / style[3]) * cols);
  if (!found) return false;
  const [cols, style] = found;
  const rows = Math.ceil(n / cols); // balanced columns, filled top to bottom
  const w = cols === 1 ? TODO_FULL_W : TODO_COL_W;
  tasks.forEach((t, i) => {
    const c = Math.floor(i / rows);
    const r = i % rows;
    const lastInColumn = r === rows - 1 || i === n - 1;
    todoRow(p, MARGIN + c * (TODO_COL_W + TODO_GUTTER), TODO_TOP + r * style[3], w, t, today, style, !lastInColumn);
  });
  return true;
}

type Slot = null | { kind: 'header'; name: string; colour: ColourName; count: number } | { kind: 'task'; task: Task } | { kind: 'more'; n: number };

/**
 * Long lists: 逾期 / 今天 / 之後 / 未排定 sections flowing through two columns of 44 px slots. A header never
 * ends a column, and a section that continues in the next column repeats its header. Every section shows at
 * least one row; then 逾期 and 今天 grow round-robin until full, then 之後 and 未排定.
 */
function todoSections(p: Page, tasks: Task[], today: number): void {
  const groups: [string, ColourName, Kind][] = [
    ['逾期', 'red', 'overdue'],
    ['今天', 'blue', 'today'],
    ['之後', 'black', 'later'],
    ['未排定', 'black', 'undated'],
  ];
  const sections = groups
    .map(([name, colour, kind]) => ({ name, colour, tasks: tasks.filter((t) => taskKind(t, today) === kind) }))
    .filter((s) => s.tasks.length);
  const capacity = SLOTS_PER_COL * 2;

  /** The slots of an allocation (null = blank slot), or undefined if it overflows. */
  const flow = (shown: number[]): Slot[] | undefined => {
    const slots: Slot[] = [];
    sections.forEach((s, i) => {
      const k = shown[i] as number;
      if (slots.length % SLOTS_PER_COL === SLOTS_PER_COL - 1) slots.push(null); // a header never ends a column
      const header: Slot = { kind: 'header', name: s.name, colour: s.colour, count: s.tasks.length };
      slots.push(header);
      const body: Slot[] = s.tasks.slice(0, k).map((task) => ({ kind: 'task', task }));
      if (k < s.tasks.length) body.push({ kind: 'more', n: s.tasks.length - k });
      for (const item of body) {
        if (slots.length % SLOTS_PER_COL === 0) slots.push(header); // sticky header: repeat it where a section continues
        slots.push(item);
      }
    });
    return slots.length <= capacity ? slots : undefined;
  };

  const shown = sections.map(() => 1);
  while (flow(shown) === undefined && sections.length > 1) {
    sections.pop();
    shown.pop();
  }
  for (const phase of [['逾期', '今天'], ['之後', '未排定']]) {
    const idx = sections.flatMap((s, i) => (phase.includes(s.name) ? [i] : []));
    for (let grew = true; grew; ) {
      grew = false;
      for (const i of idx) {
        if ((shown[i] as number) < (sections[i] as { tasks: Task[] }).tasks.length) {
          (shown[i] as number)++;
          if (flow(shown) === undefined) (shown[i] as number)--;
          else grew = true;
        }
      }
    }
  }

  const ringR = 11;
  (flow(shown) ?? []).forEach((item, s) => {
    if (item === null) return;
    const c = Math.floor(s / SLOTS_PER_COL);
    const x = MARGIN + c * (TODO_COL_W + TODO_GUTTER);
    const y = TODO_TOP + (s % SLOTS_PER_COL) * SLOT_H;
    const tx = x + 2 * ringR + 12;
    if (item.kind === 'header') {
      p.text(x, y + 30, item.name, 20, { bold: true, fill: item.colour });
      p.text(x + TODO_COL_W, y + 30, String(item.count), 20, { bold: true, fill: item.colour, anchor: 'rs' });
      p.hairlineH(x, x + TODO_COL_W, y + 38);
    } else if (item.kind === 'more') {
      p.text(tx, y + 28, more(item.n), SIZE_NOTE);
    } else {
      const t = item.task;
      const kind = taskKind(t, today);
      const base = y + 30;
      p.ring(x + ringR, base - 8, ringR, ringColour(kind), 2);
      let label: string;
      let colour: ColourName = 'black';
      let bold = false;
      if (kind === 'overdue') {
        label = overdueLabel(t, today);
        colour = 'red';
        bold = true;
      } else if (kind === 'later') {
        label = (t.due as number) - today === 1 ? '明天' : mdYear(t.due as number, today);
      } else {
        label = p.clean(t.listName); // the section header already says 今天 / 未排定: show the list instead
      }
      const lw = label ? p.text(x + TODO_COL_W, base, label, SIZE_NOTE, { bold, fill: colour, anchor: 'rs', maxw: Math.floor(TODO_COL_W / 3) }) + 12 : 0;
      p.text(tx, base, title(p, t.title), 22, { maxw: x + TODO_COL_W - tx - lw });
    }
  });
}

/** Empty state: a blue check in a circle, as Reminders shows a finished list. */
function todoDone(p: Page): void {
  const cx = W / 2;
  const cy = 224;
  p.ring(cx, cy, 32, 'blue', 3);
  p.line(
    [
      [cx - 14, cy + 1],
      [cx - 4, cy + 11],
      [cx + 15, cy - 10],
    ],
    'blue',
    4,
  );
  p.text(cx, 304, '沒有待辦事項', 30, { bold: true, anchor: 'ms' });
  p.text(cx, 338, '全部完成了', 20, { anchor: 'ms' });
}

/** 待辦: open tasks, Reminders style; overdue in red, due today in blue, both bold-labelled. */
function renderTodo(p: Page, data: AgendaData, today: number): void {
  const tasks = sortedTasks(data);
  p.text(MARGIN, HEADER_BASE, '待辦事項', 32, { bold: true, fill: 'blue' });
  p.text(W - MARGIN, HEADER_BASE, String(tasks.length), 44, { bold: true, fill: 'blue', anchor: 'rs' });

  const overdue = tasks.filter((t) => taskKind(t, today) === 'overdue').length;
  const dueToday = tasks.filter((t) => taskKind(t, today) === 'today').length;
  const parts: Part[] = [];
  if (overdue) parts.push({ text: `${overdue} 項已逾期`, colour: 'red', bold: true });
  if (dueToday) parts.push({ text: `${dueToday} 項今天到期`, colour: 'blue', bold: true });
  if (parts.length) partsLine(p, MARGIN, TODO_SUMMARY_BASE, 500, parts, SIZE_NOTE);
  drawSync(p, data, today, TODO_SUMMARY_BASE);

  if (tasks.length === 0) todoDone(p);
  else if (!todoList(p, tasks, today)) todoSections(p, tasks, today);
}

// --- The pages ---------------------------------------------------------------------------

const RENDERERS: Record<CalendarKind, (p: Page, data: AgendaData, today: number) => void> = {
  month: renderMonth,
  agenda: renderAgenda,
  todo: renderTodo,
  day: renderDay,
  monthgrid: renderMonthGrid,
};

/**
 * One calendar page as 800 x 480 palette indices, and every string drawn in order. `today` is a day
 * number (core/agenda.ts). `background` is the photo already cut and dithered to the screen (indices,
 * copied), or null for a white page; on a photo all text is white with a black outline (LAYOUTS.md, 12).
 */
export function renderCalendarPage(
  kind: CalendarKind,
  data: AgendaData,
  today: number,
  face: Typeface,
  background: Uint8Array | null = null,
): { indices: Uint8Array; texts: string[] } {
  const page = new Page(face, background);
  RENDERERS[kind](page, data, today);
  return { indices: page.indices, texts: page.drawn };
}
