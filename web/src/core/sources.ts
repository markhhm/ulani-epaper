/**
 * The calendar the Android app draws: the phone's own calendars (the calendar permission) plus the
 * iCal addresses the user added, read in memory for the window around today (`feeds.py`,
 * shared/AGENDA.md 4.2); with neither, Taiwan's public holidays straight from Google. Both the app
 * and the background sync read it through a CalendarHost (the native calendar query and HTTP),
 * so this code is the same for both and tests pass a fake.
 *
 * An address is a password: it is never put into an error message or a log, only the feed's name.
 */

import { type AgendaData, DAY, parseAgenda, ymd, type Zone } from './agenda';
import { ICalError, type ParsedFeed, parseIcal, type PayloadEvent, type PayloadReminder, wallToInstant } from './ical';
import { COLOURS, type ColourName } from './palette';

/** Google's public Taiwan holidays calendar (public data, no login): the calendar when there is none. */
export const DEFAULT_CALENDAR_URL =
  'https://calendar.google.com/calendar/ical/zh-tw.taiwan%23holiday%40group.v.calendar.google.com/public/basic.ics';
export const DEFAULT_CALENDAR_NAME = '台灣假日';

/** Colours given to the iCal addresses, in this order. */
const AUTO_COLOURS: readonly ColourName[] = ['blue', 'red', 'green', 'orange', 'yellow', 'black'];

/** An iCal address the user added: `url` is a secret. */
export interface Feed {
  id: string;
  name: string;
  url: string;
}

/** One occurrence from the phone's calendar database. */
export interface PhoneEvent {
  title: string;
  /** Epoch ms; for an all-day event, UTC midnight of its first day. */
  begin: number;
  /** Epoch ms, exclusive; for an all-day event, UTC midnight after its last day. */
  end: number;
  allDay: boolean;
  calendar: string;
  location: string;
  /** "#rrggbb" or "". */
  color: string;
}

export interface PhoneCalendars {
  /** How many calendars the phone shows (0: none set up). */
  calendars: number;
  events: PhoneEvent[];
}

/** What the platform does for this code: query the phone's calendars, download an address. */
export interface CalendarHost {
  /** The occurrences overlapping [from, to) (epoch ms), or undefined without the calendar permission. */
  phoneEvents(from: number, to: number): Promise<PhoneCalendars | undefined>;
  /** GET `url` (no cookies, redirects followed but never to plain http). */
  get(url: string): Promise<{ status: number; text: string }>;
}

export type FeedProblem = 'url' | 'http' | 'connect' | 'notIcal';

/** A feed could not be read. The message names the feed, never its address. */
export class FeedError extends Error {
  override name = 'FeedError';
  constructor(
    readonly reason: FeedProblem,
    /** The feed's name ('' while checking an address). */
    readonly feed: string,
    /** The HTTP status for `http`. */
    readonly status?: number,
  ) {
    super(`${feed ? `${feed}: ` : ''}${reason === 'http' ? `HTTP ${status}` : reason}`);
  }
}

/** Days to read: the 6-week grid of today's month and at least a month ahead (`feeds.window`). */
export function syncWindow(today: number): [number, number] {
  const { year, month } = ymd(today);
  const first = Date.UTC(year, month - 1, 1) / DAY;
  const nextMonth = Date.UTC(year, month, 1) / DAY;
  return [first - 7, Math.max(nextMonth + 14, today + 31)];
}

/** A pasted address as it is fetched: webcal:// becomes https://; only http(s) with a host, no user name in it. */
export function normalizeUrl(text: string): string {
  let url = text.trim();
  if (/^webcals?:\/\//i.test(url)) url = `https://${url.slice(url.indexOf('://') + 3)}`;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new FeedError('url', '');
  }
  if (/\s/.test(url) || !['http:', 'https:'].includes(parsed.protocol) || !parsed.hostname || parsed.username || parsed.password) {
    throw new FeedError('url', '');
  }
  return parsed.href;
}

/** The host of an address, the only part that may be shown. */
export const hostOf = (url: string): string => {
  try {
    return new URL(url).hostname;
  } catch {
    return '?';
  }
};

/** The e-mail of the person whose own Google calendar this secret address is, else "" (`feeds.owner`). */
export function feedOwner(url: string): string {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return '';
  }
  const segments = parsed.pathname.split('/');
  const at = segments.indexOf('ical');
  if (parsed.hostname !== 'calendar.google.com' || at < 0 || at === segments.length - 1) return '';
  const id = decodeURIComponent(segments[at + 1] ?? '');
  return id.includes('@') && !id.endsWith('.calendar.google.com') ? id.toLowerCase() : '';
}

const hex = (name: ColourName): string => `#${COLOURS[name].rgb.map((v) => v.toString(16).padStart(2, '0')).join('')}`;

const isoDate = (epochMs: number): string => new Date(epochMs).toISOString().slice(0, 10);

/** One address read for [from, to) (epoch ms); failures become FeedErrors naming `name`. */
async function readFeed(
  host: CalendarHost,
  url: string,
  window: [number, number],
  zone: Zone,
  name: string,
  color: string,
): Promise<ParsedFeed> {
  let page: { status: number; text: string };
  try {
    page = await host.get(url);
  } catch {
    throw new FeedError('connect', name); // never the error itself: it may repeat the address
  }
  if (page.status < 200 || page.status >= 300) throw new FeedError('http', name, page.status);
  try {
    return parseIcal(page.text, window, zone, { name, color, owner: feedOwner(url) });
  } catch (error) {
    if (error instanceof ICalError) throw new FeedError('notIcal', name);
    throw error;
  }
}

/** Check an address before it is saved: read it once (its X-WR-CALNAME and how much it holds now). */
export function probeFeed(host: CalendarHost, url: string, zone: Zone, nowMs: number): Promise<ParsedFeed> {
  return readFeed(host, url, epochWindow(zone, nowMs), zone, '', '');
}

function epochWindow(zone: Zone, nowMs: number): [number, number] {
  const today = Math.floor((nowMs + zone(nowMs) * 60_000) / DAY);
  const [first, last] = syncWindow(today);
  return [wallToInstant(zone, first * DAY), wallToInstant(zone, last * DAY)];
}

/**
 * The calendar for the pages at `nowMs`: the phone's calendars and every feed, in memory. One feed
 * failing fails the whole read (FeedError naming it), so no page silently misses a calendar.
 */
export async function readCalendar(host: CalendarHost, feeds: readonly Feed[], zone: Zone, nowMs: number): Promise<AgendaData> {
  const window = epochWindow(zone, nowMs);
  const phone = await host.phoneEvents(...window);
  const events: PayloadEvent[] = (phone?.events ?? []).map((e) => ({
    title: e.title,
    start: e.allDay ? isoDate(e.begin) : new Date(e.begin).toISOString(),
    end: e.allDay ? isoDate(e.end) : new Date(e.end).toISOString(),
    allDay: e.allDay,
    calendar: e.calendar,
    location: e.location,
    color: e.color,
  }));
  const reminders: PayloadReminder[] = [];
  const sources =
    feeds.length === 0 && !phone?.calendars
      ? [{ url: DEFAULT_CALENDAR_URL, name: DEFAULT_CALENDAR_NAME, color: '' }]
      : feeds.map((feed, i) => ({ url: feed.url, name: feed.name, color: hex(AUTO_COLOURS[i % AUTO_COLOURS.length] as ColourName) }));
  for (const source of sources) {
    const feed = await readFeed(host, source.url, window, zone, source.name, source.color);
    events.push(...feed.events);
    reminders.push(...feed.reminders);
  }
  return parseAgenda({ v: 1, events, reminders }, zone, nowMs);
}
