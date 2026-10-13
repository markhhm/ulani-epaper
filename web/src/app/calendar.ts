/**
 * Drawing the calendar pages for the screen (browser only): the font, the calendar they show and the
 * day in the phone's own time zone. The calendar is the phone's (from the iPhone Shortcut), else the
 * source set with setCalendarSource (the Android app: the phone's calendars and iCal addresses),
 * else the default one read from this site. A read is kept for a few minutes, in memory only.
 */

import { type AgendaData, localZone, todayIn } from '../core/agenda';
import { renderCalendarPage } from '../core/calendarPages';
import { DEFAULT_CALENDAR_FILE, loadDefaultCalendar } from '../core/defaultCalendar';
import type { CalendarKind } from '../core/pages';
import { calendarTypeface } from './calendarFont';

const KEEP_MS = 10 * 60_000;

/** Taiwan's public holidays, from this site, when the phone gave no calendar. */
let source = (): Promise<AgendaData> =>
  loadDefaultCalendar(`${import.meta.env.BASE_URL}${DEFAULT_CALENDAR_FILE}`, localZone, Date.now(), (url, init) => fetch(url, init));
let calendar: { data: Promise<AgendaData>; at: number } | undefined;

/** Read the calendar with `read` from now on. */
export function setCalendarSource(read: () => Promise<AgendaData>): void {
  source = read;
  calendar = undefined;
}

/** Read the calendar again the next time a page is drawn (a source was added or removed). */
export function forgetCalendar(): void {
  calendar = undefined;
}

/** The calendar read in the last few minutes, else read now; a failed read is tried again next time. */
function calendarData(): Promise<AgendaData> {
  if (!calendar || Date.now() - calendar.at > KEEP_MS) {
    const data = source();
    calendar = { data, at: Date.now() };
    data.catch(() => {
      if (calendar?.data === data) calendar = undefined;
    });
  }
  return calendar.data;
}

/** One calendar page as palette indices, drawn for today from `phone` (the phone's calendar) or the calendar source. */
export async function drawCalendar(kind: CalendarKind, phone?: AgendaData): Promise<Uint8Array> {
  const [face, data] = await Promise.all([calendarTypeface(), phone ?? calendarData()]);
  return renderCalendarPage(kind, data, todayIn(localZone, Date.now()), face).indices;
}
