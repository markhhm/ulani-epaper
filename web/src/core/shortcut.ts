/**
 * The iPhone Shortcut "Paperhue 同步" and the page it opens (shared/SHORTCUT.md on the Mac branch): the
 * Shortcut reads the phone's calendars and reminders and opens the app's page in Bluefy with
 * `?sync=1#d=<base64 of the payload JSON>` added to its address. The data sits in the fragment, which
 * is never sent to a server; the page reads it once, drops it from the address and keeps it in memory
 * only (never in storage, a cache or a log).
 */

import { type AgendaData, AgendaError, parseAgenda, type Zone } from './agenda';

/** The name the Shortcut has on the phone. */
export const SHORTCUT_NAME = 'Paperhue 同步';

/** Opens the Shortcuts app and runs it. */
export const SHORTCUT_RUN_URL = `shortcuts://run-shortcut?name=${encodeURIComponent(SHORTCUT_NAME)}`;

/** Where the signed Shortcut file lies on the site, relative to the app's page. */
export const SHORTCUT_FILE = 'shortcuts/Paperhue-Sync.shortcut';

/** What the address asked for: draw this calendar, or the data in it could not be read. */
export type SyncRequest = { calendar: AgendaData } | { unreadable: true };

/** A request from the Shortcut (`?sync=1`), or undefined when the page was opened any other way. */
export function readSyncRequest(search: string, hash: string, zone: Zone, nowMs: number): SyncRequest | undefined {
  if (new URLSearchParams(search).get('sync') !== '1') return undefined;
  const m = /^#d=(.*)$/.exec(hash);
  if (!m) return { unreadable: true };
  try {
    // A "+" may arrive as a space, and the whole value may be percent-encoded.
    const b64 = decodeURIComponent(m[1] as string).replace(/ /g, '+');
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    return { calendar: parseAgenda(JSON.parse(new TextDecoder().decode(bytes)), zone, nowMs) };
  } catch (error) {
    if (error instanceof AgendaError || error instanceof SyntaxError || error instanceof URIError || error instanceof DOMException) return { unreadable: true };
    throw error;
  }
}

/** An iPhone or iPad browser (an iPad may call itself a Mac, but a Mac has no touch screen). */
export function isIosBrowser(userAgent: string, touchPoints: number): boolean {
  return /iPhone|iPad|iPod/.test(userAgent) || (/Macintosh/.test(userAgent) && touchPoints > 1);
}

/**
 * Whether a calendar page may be sent only from the Shortcut's data. An iPhone has no calendar of its own
 * for the page: until the Shortcut has run, the pages show just the default (sample) holidays, and sending
 * one would replace the page the Shortcut synced with those.
 */
export function sendsOnlyFromShortcut(ios: boolean, phoneCalendar: boolean): boolean {
  return ios && !phoneCalendar;
}
