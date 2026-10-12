/**
 * The text the "copy log" button copies: a summary of what the page found
 * (checklist, browser, calendar download, device, status, uploads) followed
 * by the full log. Headings and checklist in the page's language; technical
 * lines and the log in English.
 */

import { getLocale, type Locale, t } from '../i18n';
import { FEED_EXPLANATIONS } from './calendarFeed';
import { describeWriteMethods, WRITE_METHODS } from './checks';
import { describeFeed, type Diagnostics, type UploadReport } from './diagnostics';
import { technicalDetail } from './errors';
import { formatBattery, formatCount, formatCrc, formatRate, formatSeconds, formatStampWithZone } from './format';

/** One line per upload, e.g. `page 1, auto, 180 B, flush 10: OK, total 31.2 s, data 29.8 s, 6.4 KB/s`. */
export function describeUpload(report: UploadReport): string {
  const { page, writeMode, chunkSize, flushEvery, resend } = report.settings;
  const settings = `page ${page}, ${writeMode}, ${chunkSize} B, flush ${flushEvery || 'off'}${resend ? ', resend' : ''}`;
  if (report.outcome === 'error') {
    const detail = technicalDetail(report.error).split('\n')[0];
    return `${settings}: ERROR after ${formatSeconds(report.totalMs)}, ${formatCount(report.sent)} / ${formatCount(report.frameBytes)} bytes: ${detail}`;
  }
  if (report.outcome === 'unchanged') return `${settings}: unchanged, ${formatSeconds(report.totalMs)}`;
  const parts = [`OK, total ${formatSeconds(report.totalMs)}`];
  if (report.dataMs !== undefined) parts.push(`data ${formatSeconds(report.dataMs)}`);
  if (report.bytesPerSecond !== undefined) parts.push(formatRate(report.bytesPerSecond));
  if (report.waitMs !== undefined) parts.push(`result after ${formatSeconds(report.waitMs)}`);
  parts.push(`${report.packets} packets of ${report.chunkSize ?? '?'} B`);
  if (report.refreshing) parts.push('panel refreshing');
  return `${settings}: ${parts.join(', ')}`;
}

/** Everything the owner should send back, as plain text. */
export function buildReport(diagnostics: Diagnostics, now: Date, page: string, locale: Locale = getLocale()): string {
  const label = (key: Parameters<typeof t>[0]) => t(key, undefined, locale);
  const lines: string[] = [];
  lines.push(label('report.title'));
  lines.push(`${label('report.time')}: ${formatStampWithZone(now)}`);
  if (page) lines.push(`${label('report.page')}: ${page}`);

  const browser = diagnostics.browser;
  if (browser) {
    lines.push(`User agent: ${browser.userAgent}`);
    const methods = browser.writeMethods
      ? WRITE_METHODS.map((name) => `${name}=${browser.writeMethods?.[name] ? 'yes' : 'no'}`).join(', ')
      : 'no BluetoothRemoteGATTCharacteristic';
    lines.push(
      `Browser: bluetooth=${browser.webBluetooth ? 'yes' : 'no'}, availability=${browser.availability}, ` +
        `secureContext=${String(browser.secureContext)}, ${methods}`,
    );
  }

  lines.push('', `${label('report.checklist')}:`, diagnostics.checklist.toText(locale));

  const feed = diagnostics.feed;
  if (feed) {
    lines.push(
      '',
      `${label('report.feed')}: ${describeFeed(feed)}`,
      t(FEED_EXPLANATIONS[feed.outcome], { status: feed.status ?? '?' }, locale),
    );
  }

  const device = diagnostics.device;
  if (device) {
    lines.push(
      '',
      `${label('report.device')}: ${device.name ?? '?'} via ${device.kind}, model ${device.model ?? '?'}, firmware ${device.firmware ?? '?'}`,
    );
  }
  if (diagnostics.deviceWriteMethods) {
    lines.push(`Image characteristic: ${describeWriteMethods(diagnostics.deviceWriteMethods)}`);
  }
  const status = diagnostics.status;
  if (status) {
    const battery = status.battery ? formatBattery(status.battery) : 'unknown';
    const slot = status.slot ? `${status.slot.slot} (crc ${formatCrc(status.slot.crc32)})` : 'unknown';
    lines.push(`${label('report.status')}: battery ${battery}, page on screen ${slot}`);
  }
  if (diagnostics.uploads.length > 0) {
    lines.push('', `${label('report.uploads')}:`);
    for (const upload of diagnostics.uploads) lines.push(`- ${describeUpload(upload)}`);
  }

  lines.push('', `${label('report.log')}:`, diagnostics.log.toText() || label('report.empty'));
  return `${lines.join('\n')}\n`;
}
