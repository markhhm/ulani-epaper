import { afterEach, describe, expect, it, vi } from 'vitest';
import { downloadFeed, FEED_TIMEOUT_MS, HOLIDAY_FEED_URL } from '../../src/spike/calendarFeed';

const ICS = [
  'BEGIN:VCALENDAR',
  'PRODID:-//Test//EN',
  'BEGIN:VEVENT',
  'SUMMARY:中秋節',
  'END:VEVENT',
  'BEGIN:VEVENT',
  'SUMMARY:國慶日',
  'END:VEVENT',
  'END:VCALENDAR',
  '',
].join('\r\n');

let clock = 0;
const now = () => (clock += 250);

afterEach(() => {
  vi.useRealTimers();
});

describe('downloadFeed', () => {
  it('asks for the public holidays feed with no credentials, no cache and no referrer', async () => {
    const fetch = vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) => new Response(ICS));
    await downloadFeed({ fetch, now });
    expect(fetch).toHaveBeenCalledTimes(1);
    const [url, init] = fetch.mock.calls[0] ?? [];
    expect(url).toBe(HOLIDAY_FEED_URL);
    expect(init).toMatchObject({
      method: 'GET',
      mode: 'cors',
      credentials: 'omit',
      cache: 'no-store',
      referrerPolicy: 'no-referrer',
    });
    expect(init?.signal).toBeInstanceOf(AbortSignal);
    expect(init).not.toHaveProperty('headers');
  });

  it('passes on calendar data, with status, size and events', async () => {
    const report = await downloadFeed({ fetch: async () => new Response(ICS, { status: 200 }), now });
    expect(report).toEqual({
      outcome: 'pass',
      url: HOLIDAY_FEED_URL,
      status: 200,
      bytes: new TextEncoder().encode(ICS).length,
      vcalendar: true,
      events: 2,
      ms: 250,
    });
  });

  it('accepts a byte order mark before BEGIN:VCALENDAR', async () => {
    const body = new Uint8Array([0xef, 0xbb, 0xbf, ...new TextEncoder().encode(ICS)]);
    const report = await downloadFeed({ fetch: async () => new Response(body), now });
    expect(report).toMatchObject({ outcome: 'pass', bytes: body.length, vcalendar: true });
  });

  it('calls an HTTP error or a web page unexpected', async () => {
    const missing = await downloadFeed({ fetch: async () => new Response('Not Found', { status: 404 }), now });
    expect(missing).toMatchObject({ outcome: 'unexpected', status: 404, bytes: 9, vcalendar: false, events: 0 });
    const page = await downloadFeed({ fetch: async () => new Response('<!doctype html><title>Sign in</title>'), now });
    expect(page).toMatchObject({ outcome: 'unexpected', status: 200, vcalendar: false });
    const error = await downloadFeed({ fetch: async () => new Response(ICS, { status: 500 }), now });
    expect(error).toMatchObject({ outcome: 'unexpected', status: 500, vcalendar: true });
  });

  it('reports what the browser said when it blocked the request', async () => {
    const cors = new TypeError('Failed to fetch');
    const report = await downloadFeed({ fetch: async () => Promise.reject(cors), now });
    expect(report).toEqual({ outcome: 'blocked', url: HOLIDAY_FEED_URL, error: cors, ms: 250 });
  });

  it('keeps the status when the body could not be read', async () => {
    const response = new Response(ICS);
    vi.spyOn(response, 'arrayBuffer').mockRejectedValue(new TypeError('network error'));
    const report = await downloadFeed({ fetch: async () => response, now });
    expect(report).toMatchObject({ outcome: 'blocked', status: 200 });
  });

  it('gives up after the timeout', async () => {
    vi.useFakeTimers();
    const fetch = (_url: RequestInfo | URL, init?: RequestInit) =>
      new Promise<Response>((_, reject) => {
        init?.signal?.addEventListener('abort', () => reject(init.signal?.reason));
      });
    const pending = downloadFeed({ fetch, now });
    await vi.advanceTimersByTimeAsync(FEED_TIMEOUT_MS);
    const report = await pending;
    expect(report.outcome).toBe('blocked');
    expect(report.error).toBeInstanceOf(DOMException);
    expect((report.error as DOMException).name).toBe('TimeoutError');
    expect((report.error as DOMException).message).toBe('no answer within 20 s');
  });
});
