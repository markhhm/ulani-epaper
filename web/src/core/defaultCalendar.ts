/**
 * The calendar shown when the user has none: Taiwan's public holidays, from a copy that
 * `.github/workflows/web.yml` makes every day (`web/scripts/tw_holidays.py`) and puts on the same site
 * as the app. Reading it from the same origin keeps the app from talking to anyone else (Google's own
 * address does not allow other sites to read it, and public data is all this copy holds).
 */

import { type AgendaData, AgendaError, parseAgenda, type Zone } from './agenda';

/** Where the file lies on the site, relative to the app's page. */
export const DEFAULT_CALENDAR_FILE = 'data/tw-holidays.json';

/** The default calendar could not be read (no file, no network, or not calendar data). */
export class CalendarUnavailable extends Error {
  override name = 'CalendarUnavailable';
}

/** Read the file at `url` (a path on the same site) with `fetchFile` (the browser's fetch) as calendar data, with times in `zone`; `nowMs` is the time of reading. */
export async function loadDefaultCalendar(
  url: string,
  zone: Zone,
  nowMs: number,
  fetchFile: (url: string, init?: RequestInit) => Promise<Response>,
): Promise<AgendaData> {
  try {
    const response = await fetchFile(url, { credentials: 'omit', cache: 'no-cache' });
    if (!response.ok) throw new CalendarUnavailable(`the default calendar answered HTTP ${response.status}`);
    return parseAgenda(await response.json(), zone, nowMs);
  } catch (error) {
    if (error instanceof CalendarUnavailable) throw error;
    const why = error instanceof AgendaError || error instanceof SyntaxError ? 'it is not calendar data' : 'it could not be loaded';
    throw new CalendarUnavailable(`the default calendar: ${why}`, { cause: error });
  }
}
