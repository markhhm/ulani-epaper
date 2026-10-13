/**
 * Calendar events and to-do tasks as the pages draw them (the model of `agenda.py`), read from the
 * payload the iPhone Shortcut and the default calendar file (`data/tw-holidays.json`) use:
 *
 *   {"v": 1, "events": [{"title", "start", "end", "allDay", "calendar", "location"?, "color"?}],
 *    "reminders": [{"title", "due": ISO 8601 | null, "list"?, "notes"?}]}
 *
 * Times are ISO 8601 with an offset. Everything is stored as the wall clock of the zone the page is
 * drawn in ("wall ms": the date and time as if they were UTC), so the layouts never meet a time zone;
 * a day is its number of days since 1970-01-01. Nothing here reads the clock.
 */

import type { ColourName } from './palette';

export const DAY = 86_400_000;

/** Minutes east of UTC at an instant (epoch ms) in some zone. */
export type Zone = (epochMs: number) => number;

export const fixedZone =
  (minutes: number): Zone =>
  () =>
    minutes;

/** The zone the browser (the phone) is in, daylight saving time included. */
export const localZone: Zone = (epochMs) => -new Date(epochMs).getTimezoneOffset();

export interface CalEvent {
  title: string;
  /** Wall ms. All-day: midnight of the first day. */
  start: number;
  /** Wall ms, exclusive. All-day: midnight after the last day. */
  end: number;
  allDay: boolean;
  calendar: string;
  location: string;
  /** The calendar's colour, "#rrggbb", or "". */
  color: string;
}

export interface Task {
  title: string;
  /** Day number, or null. */
  due: number | null;
  listName: string;
  notes: string;
}

export interface AgendaData {
  events: CalEvent[];
  tasks: Task[];
  /** Wall ms of the read, or null. */
  fetchedAt: number | null;
}

/** The data is not a calendar payload. */
export class AgendaError extends Error {
  override name = 'AgendaError';
}

// --- Days ----------------------------------------------------------------------------

export const dayNumber = (year: number, month: number, day: number): number => Date.UTC(year, month - 1, day) / DAY;

export const dayOf = (wallMs: number): number => Math.floor(wallMs / DAY);

/** Year, month (1-12) and day of a day number. */
export function ymd(day: number): { year: number; month: number; day: number } {
  const d = new Date(day * DAY);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
}

/** 0 = Monday ... 6 = Sunday (Python's `date.weekday()`). */
export const weekday = (day: number): number => (((day + 3) % 7) + 7) % 7;

/** The day number of today in `zone` at the instant `epochMs`. */
export const todayIn = (zone: Zone, epochMs: number): number => dayOf(epochMs + zone(epochMs) * 60_000);

// --- Reading -------------------------------------------------------------------------

const ISO = /^(\d{4})-(\d\d)-(\d\d)(?:[T ](\d\d):(\d\d)(?::(\d\d)(?:\.\d+)?)?)?\s*(Z|[+-]\d\d(?::?\d\d)?)?$/;

interface When {
  /** The date and time as written, as if UTC. */
  wall: number;
  hasTime: boolean;
  /** Minutes east of UTC as written, or null. */
  offset: number | null;
}

function parseWhen(value: unknown): When | undefined {
  const m = typeof value === 'string' ? ISO.exec(value.trim()) : null;
  if (!m) return undefined;
  const [, y, mo, d, h, mi, s, zone] = m;
  const wall = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h ?? 0), Number(mi ?? 0), Number(s ?? 0));
  if (Number.isNaN(wall) || new Date(wall).getUTCMonth() !== Number(mo) - 1) return undefined; // 2026-02-31
  let offset: number | null = null;
  if (zone === 'Z') offset = 0;
  else if (zone) offset = (zone.startsWith('-') ? -1 : 1) * (Number(zone.slice(1, 3)) * 60 + Number(zone.slice(3).replace(':', '') || 0));
  return { wall, hasTime: h !== undefined, offset };
}

const text = (value: unknown): string => (typeof value === 'string' ? value : '');

function readEvent(raw: unknown, zone: Zone): CalEvent | undefined {
  if (typeof raw !== 'object' || raw === null) return undefined;
  const e = raw as Record<string, unknown>;
  const start = parseWhen(e.start);
  if (!start) return undefined;
  const end = parseWhen(e.end) ?? start;
  const common = { title: text(e.title), calendar: text(e.calendar), location: text(e.location), color: text(e.color) };
  if (e.allDay === true) {
    // The dates as written. The end is exclusive: a midnight is the day after the last one, a time
    // later in the day (23:59) belongs to the last day.
    const first = dayOf(start.wall);
    let after = end.hasTime && end.wall % DAY !== 0 ? dayOf(end.wall) + 1 : dayOf(end.wall);
    if (after <= first) after = first + 1;
    return { ...common, start: first * DAY, end: after * DAY, allDay: true };
  }
  const local = (when: When): number => {
    if (when.offset === null) return when.wall;
    const instant = when.wall - when.offset * 60_000;
    return instant + zone(instant) * 60_000;
  };
  const from = local(start);
  return { ...common, start: from, end: Math.max(from, local(end)), allDay: false };
}

function readTask(raw: unknown): Task | undefined {
  if (typeof raw !== 'object' || raw === null) return undefined;
  const t = raw as Record<string, unknown>;
  const due = parseWhen(t.due);
  return { title: text(t.title), due: due ? dayOf(due.wall) : null, listName: text(t.list), notes: text(t.notes) };
}

/**
 * Read a payload, with times in `zone`; `nowMs` (epoch ms) is when it was read. An event or reminder
 * that cannot be read is left out, a payload that is not one is an AgendaError.
 */
export function parseAgenda(raw: unknown, zone: Zone, nowMs?: number): AgendaData {
  if (typeof raw !== 'object' || raw === null) throw new AgendaError('the calendar data is not an object');
  const p = raw as Record<string, unknown>;
  if (p.v !== 1) throw new AgendaError(`unknown calendar data version ${String(p.v)}`);
  const list = (value: unknown): unknown[] => {
    if (value === undefined) return [];
    if (!Array.isArray(value)) throw new AgendaError('the calendar data has no list of events');
    return value;
  };
  return {
    events: list(p.events).flatMap((e) => readEvent(e, zone) ?? []),
    tasks: list(p.reminders).flatMap((t) => readTask(t) ?? []),
    fetchedAt: nowMs === undefined ? null : nowMs + zone(nowMs) * 60_000,
  };
}

// --- Asking --------------------------------------------------------------------------

/** Events touching `day`, all-day first, then by start, then title; a zero-length event shows on its day only. */
export function eventsOn(data: AgendaData, day: number): CalEvent[] {
  const from = day * DAY;
  const to = from + DAY;
  return data.events
    .filter((e) => (e.start === e.end ? from <= e.start && e.start < to : e.start < to && e.end > from))
    .sort((a, b) => Number(!a.allDay) - Number(!b.allDay) || a.start - b.start || compare(a.title, b.title));
}

/** Open tasks: dated ones by due date, then the undated ones; ties by title. */
export function sortedTasks(data: AgendaData): Task[] {
  return [...data.tasks].sort(
    (a, b) => Number(a.due === null) - Number(b.due === null) || (a.due ?? 0) - (b.due ?? 0) || compare(a.title, b.title),
  );
}

export const compare = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

// --- Calendar colours ----------------------------------------------------------------

type Accent = Extract<ColourName, 'red' | 'orange' | 'yellow' | 'green' | 'blue' | 'black'>;

/**
 * The panel colour for a "#rrggbb" calendar colour, by hue (`image.accent`): nearest-RGB would turn
 * Google's pastel colours white. Greys and very dark colours are black; a missing or bad colour too.
 */
export function accent(colour: string | undefined): Accent {
  if (!colour || !/^#[0-9a-fA-F]{6}$/.test(colour)) return 'black';
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(colour.slice(i, i + 2), 16) / 255) as [number, number, number];
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const saturation = max === 0 ? 0 : (max - min) / max;
  if (saturation < 0.2 || max < 0.25) return 'black';
  const span = max - min;
  const hue = max === r ? (((g - b) / span) % 6 + 6) % 6 : max === g ? (b - r) / span + 2 : (r - g) / span + 4;
  const degrees = hue * 60;
  return degrees < 10 ? 'red' : degrees < 40 ? 'orange' : degrees < 75 ? 'yellow' : degrees < 165 ? 'green' : degrees < 330 ? 'blue' : 'red';
}
