/**
 * The Android app's own native parts, as the web code sees them: the Paperhue plugin
 * (PaperhuePlugin.java: the calendar permission, the phone's calendar query, the sync schedule),
 * HTTP without CORS (CapacitorHttp) for iCal addresses, and what the app keeps for the
 * background sync in the WebView's storage: the iCal addresses (secrets: only on this phone) and
 * the device it connected to last. The background page (background/main.ts) reads both.
 */

import { CapacitorHttp, registerPlugin } from '@capacitor/core';
import type { ScheduleRun } from '../core/schedule';
import type { CalendarHost, Feed, PhoneCalendars } from '../core/sources';
import type { Locale } from '../i18n';

type Permission = 'granted' | 'denied' | 'prompt' | 'prompt-with-rationale';

export interface Schedule {
  /** "HH:MM", sorted; empty: off. */
  times: string[];
  /** Newest first. */
  runs: ScheduleRun[];
  /** Android may delay the runs (the app is not excluded from battery optimisation). */
  batteryOptimized: boolean;
}

interface PaperhuePlugin {
  checkPermissions(): Promise<{ calendar: Permission }>;
  requestPermissions(options: { permissions: ['calendar'] }): Promise<{ calendar: Permission }>;
  phoneEvents(options: { from: number; to: number }): Promise<PhoneCalendars>;
  getSchedule(): Promise<Schedule>;
  /** Keep the times and plan the next run; the first time there are times, asks once about battery optimisation. */
  setSchedule(options: { times: string[]; locale: Locale }): Promise<Schedule>;
  /** Keep one chunk (base64) of a file to save; the first chunk starts a new file. */
  stageFile(options: { data: string; first: boolean }): Promise<void>;
  /** Open the system's "save as" screen for the kept file and copy it where the user chooses; `saved` is false when the user backed out. */
  saveFile(options: { name: string; type: string }): Promise<{ saved: boolean }>;
}

export const Paperhue = registerPlugin<PaperhuePlugin>('Paperhue');

const SAVE_CHUNK = 1 << 20; // bytes per call over the bridge

function base64(bytes: Uint8Array): string {
  let text = '';
  for (let at = 0; at < bytes.length; at += 0x8000) text += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
  return btoa(text);
}

/**
 * Give the user a file in the Android app, where a WebView cannot download one: the bytes go to the
 * plugin in chunks, then the system's "save as" screen asks where to put it. Resolves false when the
 * user backed out.
 */
export async function saveToPhone(
  name: string,
  bytes: Uint8Array,
  type: string,
  plugin: Pick<PaperhuePlugin, 'stageFile' | 'saveFile'> = Paperhue,
): Promise<boolean> {
  let at = 0;
  do {
    await plugin.stageFile({ data: base64(bytes.subarray(at, at + SAVE_CHUNK)), first: at === 0 });
    at += SAVE_CHUNK;
  } while (at < bytes.length);
  return (await plugin.saveFile({ name, type })).saved;
}

const FEEDS_KEY = 'paperhue.feeds';
const DEVICE_KEY = 'paperhue.device';

const isFeed = (value: unknown): value is Feed =>
  typeof value === 'object' && value !== null && ['id', 'name', 'url'].every((key) => typeof (value as Record<string, unknown>)[key] === 'string');

/** The iCal addresses the user added, in order. */
export function loadFeeds(): Feed[] {
  try {
    const list: unknown = JSON.parse(localStorage.getItem(FEEDS_KEY) ?? '[]');
    return Array.isArray(list) ? list.filter(isFeed) : [];
  } catch {
    return [];
  }
}

/** Throws when the WebView refuses storage (the caller says so). */
export function saveFeeds(feeds: readonly Feed[]): void {
  localStorage.setItem(FEEDS_KEY, JSON.stringify(feeds));
}

/** The Bluetooth address of the device the app connected to last, for the background sync. */
export function rememberDevice(deviceId: string): void {
  try {
    localStorage.setItem(DEVICE_KEY, deviceId);
  } catch {
    // the background sync then reports that it has no device
  }
}

export function rememberedDevice(): string | undefined {
  try {
    return localStorage.getItem(DEVICE_KEY) ?? undefined;
  } catch {
    return undefined;
  }
}

/** May the app read the phone's calendars? Asks the first time; with `ask`, asks again (Android may not show the question). */
export async function calendarAllowed(ask = false): Promise<boolean> {
  let { calendar } = await Paperhue.checkPermissions();
  if (calendar === 'prompt' || (ask && calendar !== 'granted')) ({ calendar } = await Paperhue.requestPermissions({ permissions: ['calendar'] }));
  return calendar === 'granted';
}

/** The phone's calendars (when the permission is granted; AndroidView asks at first use) and native HTTP. */
export const appCalendarHost: CalendarHost = {
  async phoneEvents(from, to) {
    return (await Paperhue.checkPermissions()).calendar === 'granted' ? Paperhue.phoneEvents({ from, to }) : undefined;
  },
  async get(url) {
    const response = await CapacitorHttp.get({
      url,
      responseType: 'text',
      headers: { Accept: 'text/calendar, */*' },
      connectTimeout: 30_000,
      readTimeout: 30_000,
    });
    return { status: response.status, text: typeof response.data === 'string' ? response.data : '' };
  },
};
