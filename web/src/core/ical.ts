/**
 * Events and to-dos from iCalendar (.ics) data: the port of `python/src/ulani_epaper/ical.py`
 * (shared/AGENDA.md 4.3), checked against `shared/vectors/ical-vectors.json`. ical.js (MPL-2.0) reads
 * the file and steps through RRULEs; the rest (time zones, UNTIL, RDATE / EXDATE, RECURRENCE-ID
 * overrides, the window, the limits) is done here the way Python does it.
 *
 * The result is in the payload form of `agenda.ts` (`parseAgenda` turns it into the pages' data):
 * timed values as UTC instants (ISO 8601 with Z), all-day values and due dates as YYYY-MM-DD.
 * Nothing is kept: text in, events and to-dos out.
 */

import ICAL from 'ical.js';
import { DAY, dayOf, type Zone } from './agenda';

/** At most this many occurrences of one recurring event inside the window. */
export const MAX_OCCURRENCES = 500;
/** Rule steps walked from DTSTART before an event is given up as runaway. */
export const MAX_STEPS = 200_000;

/** The data is not an iCalendar file. */
export class ICalError extends Error {
  override name = 'ICalError';
}

export interface PayloadEvent {
  title: string;
  /** ISO instant (timed) or YYYY-MM-DD (all-day). */
  start: string;
  /** Exclusive; same form as `start`. */
  end: string;
  allDay: boolean;
  calendar: string;
  location: string;
  color: string;
}

export interface PayloadReminder {
  title: string;
  /** YYYY-MM-DD in the page's zone, or null. */
  due: string | null;
  list: string;
  notes: string;
}

export interface ParsedFeed {
  /** The name given, else the calendar's X-WR-CALNAME. */
  name: string;
  /** Events that could not be read (bad rule, missing start, runaway rule). */
  skipped: number;
  events: PayloadEvent[];
  reminders: PayloadReminder[];
}

type Component = InstanceType<typeof ICAL.Component>;
/** The name RRULE lines get before ical.js reads the file. */
const RRULE = 'x-paperhue-rrule';
type Property = InstanceType<typeof ICAL.Property>;
type IcalTime = InstanceType<typeof ICAL.Time>;

/** A time zone: wall ms (the date and time as if UTC) -> epoch ms. */
interface Tz {
  toInstant(wall: number): number;
}

/** A DATE or DATE-TIME value: its wall time, and its zone (none: floating, or a date). */
interface Value {
  wall: number;
  date: boolean;
  tz: Tz | undefined;
}

// --- Time zones ------------------------------------------------------------------------

const formats = new Map<string, Intl.DateTimeFormat | null>();

/** An IANA zone name as a Zone, through Intl; undefined when the name is not one. */
export function ianaZone(name: string): Zone | undefined {
  if (!formats.has(name)) {
    let format: Intl.DateTimeFormat | null = null;
    try {
      format = new Intl.DateTimeFormat('en-US', {
        timeZone: name,
        hourCycle: 'h23',
        year: 'numeric',
        month: 'numeric',
        day: 'numeric',
        hour: 'numeric',
        minute: 'numeric',
        second: 'numeric',
      });
    } catch {
      // not a zone name
    }
    formats.set(name, format);
  }
  const format = formats.get(name);
  if (!format) return undefined;
  return (epochMs) => {
    const at = Math.floor(epochMs / 1000) * 1000;
    const p = Object.fromEntries(format.formatToParts(at).map((part) => [part.type, Number(part.value)]));
    return Math.round((Date.UTC(p.year ?? 0, (p.month ?? 1) - 1, p.day, p.hour, p.minute, p.second) - at) / 60_000);
  };
}

/**
 * The instant of a wall time (ms, as if UTC) in `zone`. A repeated wall time is its first instant; a
 * wall time skipped by a change to daylight saving time takes the offset from before the change
 * (Python's fold=0).
 */
export function wallToInstant(zone: Zone, wall: number): number {
  const instant = wall - zone(wall - zone(wall) * 60_000) * 60_000;
  if (instant + zone(instant) * 60_000 === wall) return instant;
  return wall - zone(instant - 6 * 3_600_000) * 60_000; // in a gap
}

const zoneTz = (zone: Zone): Tz => ({ toInstant: (wall) => wallToInstant(zone, wall) });

const UTC: Tz = { toInstant: (wall) => wall };

const wallOf = (t: IcalTime): number => Date.UTC(t.year, t.month - 1, t.day, t.hour, t.minute, t.second);

function icalTime(wall: number, isDate: boolean): IcalTime {
  const d = new Date(wall);
  return ICAL.Time.fromData({
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    hour: d.getUTCHours(),
    minute: d.getUTCMinutes(),
    second: d.getUTCSeconds(),
    isDate,
  });
}

const isoDate = (wall: number): string => new Date(dayOf(wall) * DAY).toISOString().slice(0, 10);

// --- Reading ---------------------------------------------------------------------------

class Reader {
  private readonly zones = new Map<string, Tz | undefined>();
  readonly floating: Tz;
  private readonly floatingZone: Zone;

  constructor(
    private readonly cal: Component,
    private readonly lo: number,
    private readonly hi: number,
    private readonly page: Zone,
  ) {
    const named = text(cal, 'x-wr-timezone');
    this.floatingZone = (named && ianaZone(named)) || page;
    this.floating = zoneTz(this.floatingZone);
  }

  /** The zone a TZID names: an IANA name, else the calendar's own VTIMEZONE; else floating. */
  private zone(tzid: string): Tz | undefined {
    if (!this.zones.has(tzid)) {
      const iana = ianaZone(tzid);
      const own = this.cal.getAllSubcomponents('vtimezone').find((c) => c.getFirstPropertyValue('tzid') === tzid);
      let tz: Tz | undefined;
      if (iana) tz = zoneTz(iana);
      else if (own) {
        const vtimezone = new ICAL.Timezone(own);
        tz = { toInstant: (wall) => ICAL.Time.fromData({ ...fields(wall), isDate: false }, vtimezone).toUnixTime() * 1000 };
      }
      this.zones.set(tzid, tz);
    }
    return this.zones.get(tzid);
  }

  /** One DATE / DATE-TIME as written on `prop`. */
  value(time: IcalTime, prop: Property): Value {
    if (time.isDate) return { wall: wallOf(time), date: true, tz: undefined };
    if (time.zone === ICAL.Timezone.utcTimezone) return { wall: wallOf(time), date: false, tz: UTC };
    const tzid = prop.getParameter('tzid');
    return { wall: wallOf(time), date: false, tz: typeof tzid === 'string' && tzid ? this.zone(tzid) : undefined };
  }

  first(comp: Component, name: string): Value | undefined {
    const prop = comp.getFirstProperty(name);
    const time = prop?.getFirstValue();
    return prop && time instanceof ICAL.Time ? this.value(time, prop) : undefined;
  }

  /** Every value of every `name` line (EXDATE, RDATE). */
  all(comp: Component, name: string): Value[] {
    return comp.getAllProperties(name).flatMap((prop) => prop.getValues().flatMap((v: unknown) => (v instanceof ICAL.Time ? [this.value(v, prop)] : [])));
  }

  instant(v: Value): number {
    return (v.tz ?? this.floating).toInstant(v.wall);
  }

  /** `value` as the same kind of value as `base` (Python's `like`). */
  like(value: Value, base: Value): Value {
    if (!base.tz) {
      if (value.date) return { wall: value.wall, date: false, tz: undefined };
      if (!value.tz) return value;
      const at = value.tz.toInstant(value.wall);
      return { wall: at + this.floatingZone(at) * 60_000, date: false, tz: undefined };
    }
    if (value.date) return { wall: value.wall + (base.wall - dayOf(base.wall) * DAY), date: false, tz: base.tz };
    return value.tz ? value : { wall: value.wall, date: false, tz: base.tz };
  }

  /** Where a value of the kind of `base` falls: an instant (zoned), else the wall time (floating). */
  key(v: Value, base: Value): number {
    return base.tz ? this.instant(v) : v.wall;
  }

  window(base: Value): [number, number] {
    if (base.tz) return [this.lo, this.hi];
    const wall = (at: number) => at + this.floatingZone(at) * 60_000;
    return [wall(this.lo), wall(this.hi)];
  }

  startAndDuration(comp: Component): { base: Value; length: number; allDay: boolean } {
    const start = this.first(comp, 'dtstart');
    if (!start) throw new Error('no DTSTART');
    const allDay = start.date;
    const base: Value = { ...start, date: false };
    let length: number;
    const end = this.first(comp, 'dtend');
    const duration = comp.getFirstPropertyValue('duration');
    if (end) {
      const until = this.like(end, base);
      if (allDay) until.wall = dayOf(until.wall) * DAY;
      length = until.tz === base.tz ? until.wall - base.wall : this.instant(until) - this.instant(base);
    } else if (duration instanceof ICAL.Duration) {
      length = duration.toSeconds() * 1000;
    } else {
      length = allDay ? DAY : 0;
    }
    if (allDay) length = Math.max(length, DAY);
    return { base, length: Math.max(length, 0), allDay };
  }

  overlaps(begin: Value, length: number, base: Value): boolean {
    const [lo, hi] = this.window(base);
    const from = this.key(begin, base);
    if (!length) return lo <= from && from < hi;
    return from < hi && this.key({ ...begin, wall: begin.wall + length }, base) > lo;
  }

  /** The occurrences of a master event in the window (RRULE, RDATE, EXDATE; DTSTART always counts). */
  occurrences(comp: Component, base: Value, length: number, allDay: boolean): Value[] {
    const ruleText = comp.getFirstPropertyValue(RRULE);
    const rdates = this.all(comp, 'rdate');
    const exdates = this.all(comp, 'exdate');
    if (ruleText === null && rdates.length === 0 && exdates.length === 0) return this.overlaps(base, length, base) ? [base] : [];
    const [lo, hi] = this.window(base);
    const found = new Map<number, Value>([[this.key(base, base), base]]);
    for (const value of rdates) found.set(this.key(this.like(value, base), base), this.like(value, base));
    if (ruleText !== null) {
      const rule = ICAL.Recur.fromString(String(ruleText)); // throws for a broken rule: this event is skipped
      const until = rule.until ? this.untilKey(rule.until, base) : undefined;
      rule.until = null;
      const steps = rule.iterator(icalTime(base.wall, allDay));
      for (let step = 0; ; step++) {
        if (step >= MAX_STEPS) throw new Error('runaway rule');
        const next = steps.next();
        if (!next) break;
        // A key is the wall time give or take a day: cheap bounds first, the exact key only near them.
        const wall = wallOf(next);
        if (wall - DAY >= hi || (until !== undefined && wall - DAY > until)) break;
        if (wall + length + DAY < lo) continue;
        const value: Value = { wall, date: false, tz: base.tz };
        const key = this.key(value, base);
        if (key >= hi || (until !== undefined && key > until)) break;
        found.set(key, value);
      }
    }
    for (const value of exdates) found.delete(this.key(this.like(value, base), base));
    return [...found]
      .sort(([a], [b]) => a - b)
      .filter(([key, value]) => key < hi && this.overlaps(value, length, base))
      .slice(0, MAX_OCCURRENCES)
      .map(([, value]) => value);
  }

  /** RRULE's UNTIL where the occurrences of `base` are compared; a date runs through that day. */
  private untilKey(time: IcalTime, base: Value): number {
    let value: Value = time.isDate
      ? { wall: wallOf(time) + DAY - 1000, date: false, tz: undefined }
      : { wall: wallOf(time), date: false, tz: time.zone === ICAL.Timezone.utcTimezone ? UTC : undefined };
    if (!base.tz) return this.like(value, base).wall;
    if (!value.tz) value = { ...value, tz: base.tz };
    return this.instant(value);
  }

  /** Identity of an occurrence, for RECURRENCE-ID: the day (all-day) or the instant. */
  occurrenceId(v: Value, allDay: boolean): number {
    if (allDay) return dayOf(v.wall);
    return this.instant(v);
  }

  event(comp: Component, begin: Value, length: number, allDay: boolean, name: string, color: string): PayloadEvent {
    const tz = begin.tz ?? this.floating;
    const [start, end] = allDay
      ? [isoDate(begin.wall), isoDate(begin.wall + length)]
      : [new Date(tz.toInstant(begin.wall)).toISOString(), new Date(tz.toInstant(begin.wall + length)).toISOString()];
    return { title: text(comp, 'summary'), start, end, allDay, calendar: name, location: text(comp, 'location'), color };
  }

  task(comp: Component, name: string): PayloadReminder | undefined {
    if (['COMPLETED', 'CANCELLED'].includes(text(comp, 'status').toUpperCase()) || comp.hasProperty('completed')) return undefined;
    if (text(comp, 'percent-complete') === '100') return undefined;
    const title = text(comp, 'summary');
    if (!title) return undefined;
    const due = this.first(comp, 'due');
    let day: string | null = null;
    if (due) {
      const at = due.tz ? due.tz.toInstant(due.wall) : undefined;
      day = isoDate(at === undefined ? due.wall : at + this.page(at) * 60_000);
    }
    const notes = text(comp, 'description').split(/\r?\n/).map((line) => line.trim()).find((line) => line) ?? '';
    return { title, due: day, list: name, notes };
  }
}

function fields(wall: number) {
  const d = new Date(wall);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate(), hour: d.getUTCHours(), minute: d.getUTCMinutes(), second: d.getUTCSeconds() };
}

function text(comp: Component, name: string): string {
  const value = comp.getFirstPropertyValue(name);
  return value === null || value === undefined ? '' : String(value).trim();
}

/** The owner's own ATTENDEE line says PARTSTAT=DECLINED (Google keeps declined invitations in the feed). */
function declined(comp: Component, owner: string): boolean {
  if (!owner) return false;
  for (const attendee of comp.getAllProperties('attendee')) {
    if (String(attendee.getFirstValue()).toLowerCase().replace(/^mailto:/, '') === owner.toLowerCase()) {
      return String(attendee.getParameter('partstat') ?? '').toUpperCase() === 'DECLINED';
    }
  }
  return false;
}

/**
 * Events overlapping [window[0], window[1]) (epoch ms) and every open to-do of one .ics file. `zone`
 * is the zone the pages are drawn in (due dates are read in it, and floating times without
 * X-WR-TIMEZONE). `name` and `color` go onto every event and to-do; events whose ATTENDEE line for
 * `owner` (an e-mail address) says DECLINED are left out.
 */
export function parseIcal(
  data: string,
  window: readonly [number, number],
  zone: Zone,
  options: { name?: string; color?: string; owner?: string } = {},
): ParsedFeed {
  let cal: Component;
  try {
    // An event's RRULE is read as plain text here and parsed per event, so a broken rule skips only
    // its event. VTIMEZONE blocks keep theirs: ical.js reads them for the daylight saving changes.
    const events = data.replace(/^BEGIN:VTIMEZONE[\s\S]*?^END:VTIMEZONE|^RRULE(?=[;:])/gim, (match) => (match.length > 5 ? match : RRULE));
    const jcal: unknown = ICAL.parse(events);
    const root = Array.isArray(jcal) && Array.isArray(jcal[0]) ? jcal[0] : jcal;
    if (!Array.isArray(root) || root[0] !== 'vcalendar') throw new ICalError('no VCALENDAR');
    cal = new ICAL.Component(root);
  } catch (error) {
    throw new ICalError(`not an iCalendar file (${error instanceof Error ? error.message : 'unreadable'})`, { cause: error });
  }
  const { color = '', owner = '' } = options;
  const name = options.name || text(cal, 'x-wr-calname');
  const reader = new Reader(cal, window[0], window[1], zone);
  const feed: ParsedFeed = { name, skipped: 0, events: [], reminders: [] };

  const masters: Component[] = [];
  const overrides = new Map<string, Component[]>();
  for (const comp of cal.getAllSubcomponents('vevent')) {
    if (comp.hasProperty('recurrence-id')) overrides.set(text(comp, 'uid'), [...(overrides.get(text(comp, 'uid')) ?? []), comp]);
    else masters.push(comp);
  }

  for (const comp of masters) {
    if (text(comp, 'status').toUpperCase() === 'CANCELLED' || declined(comp, owner)) continue;
    try {
      const { base, length, allDay } = reader.startAndDuration(comp);
      const moved = new Set(
        (overrides.get(text(comp, 'uid')) ?? []).flatMap((o) => {
          const id = reader.first(o, 'recurrence-id');
          return id ? [reader.occurrenceId(id, allDay)] : [];
        }),
      );
      for (const begin of reader.occurrences(comp, base, length, allDay)) {
        if (!moved.has(reader.occurrenceId(begin, allDay))) feed.events.push(reader.event(comp, begin, length, allDay, name, color));
      }
    } catch {
      feed.skipped += 1;
    }
  }

  for (const comp of [...overrides.values()].flat()) {
    if (text(comp, 'status').toUpperCase() === 'CANCELLED' || declined(comp, owner)) continue; // the master skipped it above
    try {
      const { base, length, allDay } = reader.startAndDuration(comp);
      if (reader.overlaps(base, length, base)) feed.events.push(reader.event(comp, base, length, allDay, name, color));
    } catch {
      feed.skipped += 1;
    }
  }

  for (const comp of cal.getAllSubcomponents('vtodo')) {
    try {
      const task = reader.task(comp, name);
      if (task) feed.reminders.push(task);
    } catch {
      feed.skipped += 1;
    }
  }
  return feed;
}
