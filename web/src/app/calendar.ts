/**
 * Drawing the calendar pages for the screen (browser only): the font, the calendar they show (the phone's,
 * from the iPhone Shortcut, else the default one read once per page load from this site) and the day in
 * the phone's own time zone.
 */

import { type AgendaData, localZone, todayIn } from '../core/agenda';
import { renderCalendarPage } from '../core/calendarPages';
import { DEFAULT_CALENDAR_FILE, loadDefaultCalendar } from '../core/defaultCalendar';
import type { CalendarKind } from '../core/pages';
import { calendarTypeface } from './calendarFont';

let calendar: Promise<AgendaData> | undefined;

/** The calendar the pages show when the phone gave none: Taiwan's public holidays; a failed read is tried again next time. */
function calendarData(): Promise<AgendaData> {
  calendar ??= loadDefaultCalendar(`${import.meta.env.BASE_URL}${DEFAULT_CALENDAR_FILE}`, localZone, Date.now(), (url, init) => fetch(url, init)).catch((error: unknown) => {
    calendar = undefined;
    throw error;
  });
  return calendar;
}

/** One calendar page as palette indices, drawn for today from `phone` (the phone's calendar) or the default calendar. */
export async function drawCalendar(kind: CalendarKind, phone?: AgendaData): Promise<Uint8Array> {
  const [face, data] = await Promise.all([calendarTypeface(), phone ?? calendarData()]);
  return renderCalendarPage(kind, data, todayIn(localZone, Date.now()), face).indices;
}
