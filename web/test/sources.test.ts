import { describe, expect, it } from 'vitest';
import { dayNumber, eventsOn, fixedZone } from '../src/core/agenda';
import { COLOURS } from '../src/core/palette';
import {
  type CalendarHost,
  DEFAULT_CALENDAR_URL,
  FeedError,
  feedOwner,
  normalizeUrl,
  type PhoneCalendars,
  probeFeed,
  readCalendar,
  syncWindow,
} from '../src/core/sources';

const TPE = fixedZone(480);
const NOW = Date.parse('2026-10-13T08:00:00+08:00');
const TODAY = dayNumber(2026, 10, 13);
/** The first automatic colour of an iCal address (feeds.AUTO_COLOURS). */
const BLUE = `#${COLOURS.blue.rgb.map((v) => v.toString(16).padStart(2, '0')).join('')}`;
const SECRET = 'https://calendar.google.com/calendar/ical/me%40gmail.com/private-abc123/basic.ics';

const ICS = [
  'BEGIN:VCALENDAR',
  'BEGIN:VEVENT',
  'UID:a',
  'SUMMARY:週會',
  'DTSTART:20261013T020000Z',
  'DTEND:20261013T030000Z',
  'END:VEVENT',
  'BEGIN:VTODO',
  'UID:t',
  'SUMMARY:繳電費',
  'DUE;VALUE=DATE:20261015',
  'END:VTODO',
  'END:VCALENDAR',
].join('\r\n');

function host(phone: PhoneCalendars | undefined, pages: Record<string, { status: number; text: string } | Error>) {
  const asked: { phone: [number, number][]; urls: string[] } = { phone: [], urls: [] };
  const fake: CalendarHost = {
    async phoneEvents(from, to) {
      asked.phone.push([from, to]);
      return phone;
    },
    async get(url) {
      asked.urls.push(url);
      const page = pages[url];
      if (page instanceof Error) throw page;
      return page ?? { status: 404, text: '' };
    },
  };
  return { fake, asked };
}

const PHONE: PhoneCalendars = {
  calendars: 1,
  events: [
    { title: '牙醫', begin: Date.parse('2026-10-13T06:00:00Z'), end: Date.parse('2026-10-13T07:00:00Z'), allDay: false, calendar: '個人', location: '', color: '#0b8043' },
    { title: '國慶日', begin: Date.UTC(2026, 9, 10), end: Date.UTC(2026, 9, 11), allDay: true, calendar: '假日', location: '', color: '' },
  ],
};

describe('calendar sources on the phone', () => {
  it('reads the month around today and at least a month ahead (feeds.window)', () => {
    expect(syncWindow(TODAY)).toEqual([dayNumber(2026, 9, 24), dayNumber(2026, 11, 15)]);
    expect(syncWindow(dayNumber(2026, 10, 31))).toEqual([dayNumber(2026, 9, 24), dayNumber(2026, 12, 1)]);
  });

  it("merges the phone's calendars with the iCal addresses (automatic colours), in the phone's time zone", async () => {
    const { fake, asked } = host(PHONE, { [SECRET]: { status: 200, text: ICS } });
    const data = await readCalendar(fake, [{ id: 'f1', name: '工作', url: SECRET }], TPE, NOW);
    expect(asked.phone).toEqual([[Date.parse('2026-09-24T00:00:00+08:00'), Date.parse('2026-11-15T00:00:00+08:00')]]);
    expect(eventsOn(data, TODAY).map((e) => [e.title, e.calendar, e.color, new Date(e.start).toISOString().slice(11, 16)])).toEqual([
      ['週會', '工作', BLUE, '10:00'],
      ['牙醫', '個人', '#0b8043', '14:00'],
    ]);
    expect(eventsOn(data, dayNumber(2026, 10, 10)).map((e) => [e.title, e.allDay])).toEqual([['國慶日', true]]);
    expect(data.tasks.map((t) => [t.title, t.listName, t.due])).toEqual([['繳電費', '工作', dayNumber(2026, 10, 15)]]);
    expect(data.fetchedAt).toBe(NOW + 8 * 3_600_000);
  });

  it("shows Taiwan's public holidays when there is no calendar at all", async () => {
    const holidays = ICS.replace('週會', '國慶日');
    for (const phone of [undefined, { calendars: 0, events: [] }]) {
      const { fake, asked } = host(phone, { [DEFAULT_CALENDAR_URL]: { status: 200, text: holidays } });
      const data = await readCalendar(fake, [], TPE, NOW);
      expect(asked.urls).toEqual([DEFAULT_CALENDAR_URL]);
      expect(data.events.map((e) => e.title)).toEqual(['國慶日']);
    }
  });

  it("does not add the holidays to the phone's own calendars", async () => {
    const { fake, asked } = host(PHONE, {});
    await readCalendar(fake, [], TPE, NOW);
    expect(asked.urls).toEqual([]);
  });

  it('fails the whole read when one address fails, naming the feed but never its address', async () => {
    for (const page of [{ status: 404, text: '' }, { status: 200, text: '<html>sign in</html>' }, new TypeError(`failed to fetch ${SECRET}`)]) {
      const { fake } = host(PHONE, { [SECRET]: page });
      const failure = await readCalendar(fake, [{ id: 'f1', name: '工作', url: SECRET }], TPE, NOW).catch((e: unknown) => e);
      expect(failure).toBeInstanceOf(FeedError);
      expect((failure as FeedError).feed).toBe('工作');
      expect(String((failure as Error).message)).not.toContain('private-abc123');
      expect(String((failure as Error).message)).not.toContain('me%40gmail');
    }
  });

  it('checks an address before it is saved: its own name and what it holds now', async () => {
    const { fake } = host(undefined, { [SECRET]: { status: 200, text: ICS.replace('BEGIN:VEVENT', 'X-WR-CALNAME:公司\r\nBEGIN:VEVENT') } });
    const feed = await probeFeed(fake, SECRET, TPE, NOW);
    expect([feed.name, feed.events.length, feed.reminders.length]).toEqual(['公司', 1, 1]);
    const { fake: missing } = host(undefined, {});
    await expect(probeFeed(missing, SECRET, TPE, NOW)).rejects.toMatchObject({ reason: 'http', status: 404 });
  });

  it('accepts http(s) and webcal addresses only, and knows whose Google calendar a secret address is', () => {
    expect(normalizeUrl('  webcal://example.com/a.ics ')).toBe('https://example.com/a.ics');
    for (const bad of ['ftp://example.com/a.ics', 'not an address', 'https://user:pw@example.com/a.ics']) {
      expect(() => normalizeUrl(bad)).toThrow(FeedError);
    }
    expect(feedOwner(SECRET)).toBe('me@gmail.com');
    expect(feedOwner('https://calendar.google.com/calendar/ical/abc%40group.calendar.google.com/private-x/basic.ics')).toBe('');
    expect(feedOwner('https://example.com/ical/me%40gmail.com/basic.ics')).toBe('');
  });
});
