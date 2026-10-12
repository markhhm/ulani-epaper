/**
 * The calendar download test of the diagnostics page: can this browser fetch
 * a public iCal feed straight from its source? Calendar pages need that, and
 * a browser blocks it when the server does not allow cross-origin reads
 * (CORS). No Bluetooth involved.
 *
 * The feed below is the page's only address outside the site, and the page
 * fetches it only when the user taps the button (test/spike/selfContained.test.ts
 * holds it to that). No credentials, no proxy: the request goes from the
 * browser to the feed, as a calendar sync would.
 */

import type { StringKey } from '../i18n';

/** Taiwan's public holidays, as a public iCal feed from Google Calendar. */
export const HOLIDAY_FEED_URL =
  'https://calendar.google.com/calendar/ical/zh-tw.taiwan%23holiday%40group.v.calendar.google.com/public/basic.ics';

/** The one-line explanation of each outcome (a key of src/i18n.ts). */
export const FEED_EXPLANATIONS = Object.freeze({
  pass: 'feed.explain.pass',
  unexpected: 'feed.explain.unexpected',
  blocked: 'feed.explain.blocked',
} as const satisfies Record<FeedOutcome, StringKey>);

/** Give up after this long (connecting and reading the body). */
export const FEED_TIMEOUT_MS = 20_000;

/**
 * - `pass`: an OK response whose body starts with BEGIN:VCALENDAR.
 * - `unexpected`: a response the page could read, but not an OK one with
 *   calendar data (an HTTP error, a login page).
 * - `blocked`: fetch() failed: CORS, no network, a timeout.
 */
export type FeedOutcome = 'pass' | 'unexpected' | 'blocked';

export interface FeedReport {
  readonly outcome: FeedOutcome;
  readonly url: string;
  /** HTTP status, when a response came back. */
  readonly status?: number;
  /** Body size in bytes, when it was read. */
  readonly bytes?: number;
  /** The body starts with BEGIN:VCALENDAR (after a byte order mark, if any). */
  readonly vcalendar?: boolean;
  /** BEGIN:VEVENT lines in the body. */
  readonly events?: number;
  /** Why fetch() or reading the body failed (`blocked`). */
  readonly error?: unknown;
  /** Start to result. */
  readonly ms: number;
}

export interface FeedOptions {
  /** Default: the browser's fetch(). */
  readonly fetch?: typeof fetch;
  readonly url?: string;
  readonly timeoutMs?: number;
  /** Monotonic clock for the duration. Default performance.now(). */
  readonly now?: () => number;
}

/** Download the feed once and say what came back. Never rejects. */
export async function downloadFeed(options: FeedOptions = {}): Promise<FeedReport> {
  const url = options.url ?? HOLIDAY_FEED_URL;
  const now = options.now ?? (() => performance.now());
  // Called through globalThis: some browsers refuse a detached window.fetch.
  const get = options.fetch ?? ((input: RequestInfo | URL, init?: RequestInit) => globalThis.fetch(input, init));
  const timeoutMs = options.timeoutMs ?? FEED_TIMEOUT_MS;
  const controller = new AbortController();
  const timer = setTimeout(() => {
    controller.abort(new DOMException(`no answer within ${Math.round(timeoutMs / 1000)} s`, 'TimeoutError'));
  }, timeoutMs);
  const start = now();
  let status: number | undefined;
  try {
    const response = await get(url, {
      method: 'GET',
      mode: 'cors',
      credentials: 'omit',
      cache: 'no-store',
      redirect: 'follow',
      referrerPolicy: 'no-referrer',
      signal: controller.signal,
    });
    status = response.status;
    const body = new Uint8Array(await response.arrayBuffer());
    // TextDecoder drops a leading byte order mark.
    const text = new TextDecoder().decode(body);
    const vcalendar = text.startsWith('BEGIN:VCALENDAR');
    const events = text.match(/^BEGIN:VEVENT\r?$/gm)?.length ?? 0;
    return {
      outcome: response.ok && vcalendar ? 'pass' : 'unexpected',
      url,
      status,
      bytes: body.length,
      vcalendar,
      events,
      ms: now() - start,
    };
  } catch (error) {
    return { outcome: 'blocked', url, ...(status === undefined ? {} : { status }), error, ms: now() - start };
  } finally {
    clearTimeout(timer);
  }
}
