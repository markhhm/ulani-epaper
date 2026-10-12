import { describe, expect, it } from 'vitest';
import { dayNumber, eventsOn, fixedZone } from '../src/core/agenda';
import { CalendarUnavailable, DEFAULT_CALENDAR_FILE, loadDefaultCalendar } from '../src/core/defaultCalendar';

const HOLIDAYS = {
  v: 1,
  events: [
    { title: '國慶日', start: '2026-10-10T00:00:00+08:00', end: '2026-10-11T00:00:00+08:00', allDay: true, calendar: '台灣假日' },
  ],
  reminders: [],
};
const NOW = Date.UTC(2026, 9, 12, 1, 0);
const TPE = fixedZone(480);

function fake(response: () => Response | Promise<Response>) {
  const calls: { url: string; init: RequestInit | undefined }[] = [];
  const fetchFile = async (url: string, init?: RequestInit) => {
    calls.push({ url, init });
    return response();
  };
  return { calls, fetchFile };
}

describe('the default calendar', () => {
  it('is read from a file next to the page, with no credentials, and drawn like any calendar', async () => {
    const { calls, fetchFile } = fake(() => Response.json(HOLIDAYS));
    const data = await loadDefaultCalendar('./' + DEFAULT_CALENDAR_FILE, TPE, NOW, fetchFile);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe('./data/tw-holidays.json');
    expect(new URL(calls[0]?.url as string, 'https://markhhm.github.io/paperhue/').origin).toBe('https://markhhm.github.io'); // same origin
    expect(calls[0]?.init).toMatchObject({ credentials: 'omit' });
    expect(data.fetchedAt).toBe(Date.UTC(2026, 9, 12, 9, 0));
    expect(eventsOn(data, dayNumber(2026, 10, 10)).map((e) => e.title)).toEqual(['國慶日']);
  });

  it.each([
    ['a missing file', () => new Response('', { status: 404 })],
    ['a page that is not JSON', () => new Response('<html>not found</html>')],
    ['JSON that is not calendar data', () => Response.json({ v: 9 })],
  ])('says it is unavailable for %s', async (_, response) => {
    const { fetchFile } = fake(response);
    await expect(loadDefaultCalendar('data/tw-holidays.json', TPE, NOW, fetchFile)).rejects.toBeInstanceOf(CalendarUnavailable);
  });

  it('says it is unavailable when the network fails', async () => {
    const { fetchFile } = fake(() => Promise.reject(new TypeError('Failed to fetch')));
    await expect(loadDefaultCalendar('data/tw-holidays.json', TPE, NOW, fetchFile)).rejects.toBeInstanceOf(CalendarUnavailable);
  });
});
