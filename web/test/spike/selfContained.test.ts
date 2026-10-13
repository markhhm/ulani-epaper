/**
 * The diagnostics page must work offline once loaded and must not pull in
 * anything from elsewhere: no URLs to other sites in its HTML, scripts,
 * styles or strings. The one exception is the calendar download test, which
 * fetches a single public iCal feed when the user taps its button.
 */

import { describe, expect, it } from 'vitest';
import spikeHtml from '../../spike.html?raw';
import { HOLIDAY_FEED_URL } from '../../src/spike/calendarFeed';

/**
 * Everything the page's script is built from (src/app/ is the other page; core/sources.ts reads the
 * Android app's calendars and is not part of this page).
 */
const sources = {
  ...import.meta.glob<string>('../../src/spike/**/*', { query: '?raw', import: 'default', eager: true }),
  ...import.meta.glob<string>(['../../src/{ble,core,session}/**/*', '!../../src/core/sources.ts'], {
    query: '?raw',
    import: 'default',
    eager: true,
  }),
  ...import.meta.glob<string>('../../src/*.ts', { query: '?raw', import: 'default', eager: true }),
};

/** The only outside address, written out here so a change to it shows up in review. */
const ALLOWED =
  'https://calendar.google.com/calendar/ical/zh-tw.taiwan%23holiday%40group.v.calendar.google.com/public/basic.ics';

/** `http://…`, `https://…`, or a protocol-relative `"//host…"` in a string, attribute or url(). */
const EXTERNAL = /https?:\/\/|["'(=]\s*\/\/[a-z0-9]/i;

function files(): [string, string][] {
  return [['spike.html', spikeHtml], ...Object.entries(sources)];
}

describe('the diagnostics page is self-contained', () => {
  it('has sources to check', () => {
    const names = Object.keys(sources).map((path) => path.slice(path.lastIndexOf('/') + 1));
    expect(names).toEqual(
      expect.arrayContaining(['main.ts', 'view.ts', 'spike.css', 'calendarFeed.ts', 'i18n.ts', 'webBluetooth.ts', 'session.ts']),
    );
  });

  it('links nothing outside the site but the calendar feed', () => {
    for (const [path, text] of files()) {
      expect(EXTERNAL.exec(text.split(ALLOWED).join(''))?.[0], path).toBeUndefined();
    }
  });

  it('names the calendar feed once, as the download test address', () => {
    expect(HOLIDAY_FEED_URL).toBe(ALLOWED);
    const uses = files().flatMap(([path, text]) => Array(text.split(ALLOWED).length - 1).fill(path) as string[]);
    expect(uses).toHaveLength(1);
    expect(uses[0]).toMatch(/\/src\/spike\/calendarFeed\.ts$/);
  });

  it('fetches only in the calendar download test', () => {
    for (const [path, text] of files()) {
      if (path.endsWith('/calendarFeed.ts')) continue;
      const code = text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
      expect(/\bfetch\s*\(|XMLHttpRequest|new\s+WebSocket|EventSource|sendBeacon/.exec(code)?.[0], path).toBeUndefined();
    }
  });
});
