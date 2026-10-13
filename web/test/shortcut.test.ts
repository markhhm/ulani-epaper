import { describe, expect, it } from 'vitest';
import { dayNumber, fixedZone } from '../src/core/agenda';
import { isIosBrowser, readSyncRequest, sendsOnlyFromShortcut, SHORTCUT_RUN_URL } from '../src/core/shortcut';

const TPE = fixedZone(8 * 60);
const NOW = Date.UTC(2026, 9, 13, 1, 0);
const wall = (y: number, m: number, d: number, h = 0, min = 0) => Date.UTC(y, m - 1, d, h, min);

/** What the Shortcut puts after `#d=`: the JSON as UTF-8, in standard base64. */
function encode(json: string): string {
  return btoa(String.fromCharCode(...new TextEncoder().encode(json)));
}

/** The Shortcut's payload (shared/SHORTCUT.md): `/` escaped, keys in any order, all-day events ending at 23:59:59. */
const PAYLOAD = JSON.stringify({
  v: 1,
  events: [
    { title: '週會', start: '2026-10-13T09:00:00+08:00', end: '2026-10-13T10:00:00+08:00', allDay: false, calendar: '工作' },
    { allDay: true, calendar: '節日', end: '2026-10-14T23:59:59+08:00', start: '2026-10-13T00:00:00+08:00', title: '連假' },
    { title: 'UTC call', start: '2026-10-13T01:00:00Z', end: '2026-10-13T02:00:00Z', allDay: false, calendar: 'x' },
  ],
  reminders: [
    { title: '繳費', due: '2026-10-14T00:00:00+08:00' },
    { title: '買牛奶', due: null },
  ],
}).replace(/\//g, '\\/');

const read = (search: string, hash: string) => readSyncRequest(search, hash, TPE, NOW);

describe('reading what the Shortcut sends', () => {
  it('is not a sync request unless the address says ?sync=1', () => {
    expect(read('', `#d=${encode(PAYLOAD)}`)).toBeUndefined();
    expect(read('?sync=0', `#d=${encode(PAYLOAD)}`)).toBeUndefined();
  });

  it('turns the payload into calendar data in the phone’s time zone', () => {
    const request = read('?sync=1', `#d=${encode(PAYLOAD)}`);
    if (!request || !('calendar' in request)) throw new Error('expected calendar data');
    const { events, tasks } = request.calendar;
    expect(events.map((e) => e.title)).toEqual(['週會', '連假', 'UTC call']);
    expect(events[0]).toMatchObject({ start: wall(2026, 10, 13, 9), end: wall(2026, 10, 13, 10), allDay: false });
    // end = 23:59:59 of the last day means the day after it, exclusive
    expect(events[1]).toMatchObject({ allDay: true, start: wall(2026, 10, 13), end: wall(2026, 10, 15) });
    expect(events[2]?.start).toBe(wall(2026, 10, 13, 9)); // "Z" is 01:00 UTC = 09:00 in Taipei
    expect(tasks.map((t) => t.due)).toEqual([dayNumber(2026, 10, 14), null]);
    expect(request.calendar.fetchedAt).toBe(NOW + 8 * 3600_000);
  });

  it('copes with the way the address travels: percent-encoded, plus signs turned into spaces', () => {
    const b64 = encode('{"v":1,"events":[{"title":">>>???","start":"2026-10-13T09:00:00+08:00","end":"2026-10-13T10:00:00+08:00","allDay":false,"calendar":""}],"reminders":[]}');
    expect(b64).toMatch(/\+/);
    expect(b64).toMatch(/\//);
    const forms = [b64, encodeURIComponent(b64), b64.replace(/\+/g, ' ')];
    for (const form of forms) {
      const request = read('?sync=1', `#d=${form}`);
      expect(request && 'calendar' in request && request.calendar.events[0]?.title, form).toBe('>>>???');
    }
  });

  it('says so when the data is missing, damaged or not version 1', () => {
    const bad = ['', '#d=', '#d=!!!', `#d=${encode('not json')}`, `#d=${encode('{"v":2,"events":[],"reminders":[]}')}`];
    for (const hash of bad) expect(read('?sync=1', hash), hash).toEqual({ unreadable: true });
  });
});

describe('the iPhone', () => {
  it('runs the Shortcut called "Paperhue-Sync"', () => {
    expect(SHORTCUT_RUN_URL).toBe('shortcuts://run-shortcut?name=Paperhue-Sync');
  });

  it('knows an iPhone or iPad browser, also one that says it is a Mac', () => {
    expect(isIosBrowser('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148', 5)).toBe(true);
    expect(isIosBrowser('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15', 5)).toBe(true);
    expect(isIosBrowser('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15', 0)).toBe(false);
    expect(isIosBrowser('Mozilla/5.0 (Linux; Android 15) Chrome/130.0 Mobile Safari/537.36', 5)).toBe(false);
  });

  it('sends a calendar page only from the Shortcut’s data: before it ran, a page would hold just the sample holidays', () => {
    expect(sendsOnlyFromShortcut(true, false)).toBe(true);
    expect(sendsOnlyFromShortcut(true, true)).toBe(false); // the Shortcut has run: its data is in the page
    expect(sendsOnlyFromShortcut(false, false)).toBe(false); // everything else has a calendar of its own
  });
});
