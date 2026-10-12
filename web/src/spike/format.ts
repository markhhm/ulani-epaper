/**
 * Formatting for the diagnostics page: times, durations, sizes, speeds and
 * battery levels. Dates use the browser's local time zone.
 */

import type { Battery } from '../core/protocol';
import { type Locale, t } from '../i18n';

function pad(value: number, width = 2): string {
  return String(value).padStart(width, '0');
}

/** `YYYY-MM-DD HH:MM:SS` in local time, e.g. `2026-10-12 14:03:22`. */
export function formatStamp(date: Date): string {
  const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  return `${day} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

/** formatStamp plus the offset from UTC, e.g. `2026-10-12 14:03:22 UTC+08:00`. */
export function formatStampWithZone(date: Date): string {
  const offset = -date.getTimezoneOffset();
  const sign = offset < 0 ? '-' : '+';
  const minutes = Math.abs(offset);
  return `${formatStamp(date)} UTC${sign}${pad(Math.floor(minutes / 60))}:${pad(minutes % 60)}`;
}

/** Local time of day with milliseconds, e.g. `14:03:22.045`, for log lines. */
export function formatClock(epochMs: number): string {
  const date = new Date(epochMs);
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(date.getMilliseconds(), 3)}`;
}

/** Milliseconds as seconds with one decimal, e.g. `32.1 s`. */
export function formatSeconds(ms: number): string {
  return `${(Math.max(0, ms) / 1000).toFixed(1)} s`;
}

/** A whole number with thin groups of three digits, e.g. `192 000`. */
export function formatCount(value: number): string {
  return String(Math.round(value)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
}

/** Bytes per second as kilobytes (1 000 bytes) per second, e.g. `6.1 KB/s`. */
export function formatRate(bytesPerSecond: number): string {
  return `${(bytesPerSecond / 1000).toFixed(1)} KB/s`;
}

/** Share of `part` in `whole` as a whole percentage (0 when `whole` is 0). */
export function percent(part: number, whole: number): number {
  if (whole <= 0) return 0;
  return Math.min(100, Math.max(0, Math.floor((part / whole) * 100)));
}

/** Battery state for people: `4 / 5`, or `充電中` / `charging` (English by default, as in the log). */
export function formatBattery(battery: Battery, locale: Locale = 'en'): string {
  if (battery.charging || battery.level === null) return t('value.charging', undefined, locale);
  return `${battery.level} / 5`;
}

/** A CRC-32 as eight lower-case hex digits. */
export function formatCrc(crc: number): string {
  return (crc >>> 0).toString(16).padStart(8, '0');
}
