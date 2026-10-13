import { describe, expect, it } from 'vitest';
import { fixedZone } from '../src/core/agenda';
import { ICalError, parseIcal, type PayloadEvent } from '../src/core/ical';
import { vectorFile } from './vectors';

const files = import.meta.glob<string>('../../shared/vectors/ical/*.ics', { eager: true, query: '?raw', import: 'default' });
const ics = (name: string): string => files[`../../shared/vectors/ical/${name}`] as string;

interface Case {
  file: string;
  window: [string, string];
  name: string;
  skipped: number;
  events: { title: string; start: string; end: string; all_day: boolean; location: string }[];
  tasks: { title: string; due: string | null; notes: string }[];
}

const TPE = fixedZone(480);
const OCT: [number, number] = [Date.parse('2026-10-01T00:00:00+08:00'), Date.parse('2026-11-01T00:00:00+08:00')];

/** A timed value as the vectors write it (in +08:00); dates stay as they are. */
function inTaipei(value: string, allDay: boolean): string {
  if (allDay) return value;
  return `${new Date(Date.parse(value) + 8 * 3_600_000).toISOString().slice(0, 19)}+08:00`;
}

const rows = (events: PayloadEvent[]) =>
  events
    .map((e) => ({ title: e.title, start: inTaipei(e.start, e.allDay), end: inTaipei(e.end, e.allDay), all_day: e.allDay, location: e.location }))
    .sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : a.title < b.title ? -1 : a.title > b.title ? 1 : 0));

const cal = (...lines: string[]) => `BEGIN:VCALENDAR\r\n${lines.map((l) => `${l}\r\n`).join('')}END:VCALENDAR\r\n`;

describe('iCalendar feeds', () => {
  const { cases } = vectorFile<{ cases: Case[] }>('ical-vectors.json');

  it.each(cases.map((c) => [c.file, c.window[0], c] as const))('%s from %s matches the Python reference', (_file, _from, c) => {
    const feed = parseIcal(ics(c.file), [Date.parse(c.window[0]), Date.parse(c.window[1])], TPE);
    expect(feed.name).toBe(c.name);
    expect(feed.skipped).toBe(c.skipped);
    expect(rows(feed.events)).toEqual(c.events);
    const tasks = feed.reminders.map((t) => ({ title: t.title, due: t.due, notes: t.notes })).sort((a, b) => (a.title < b.title ? -1 : 1));
    expect(tasks).toEqual(c.tasks);
  });

  it('puts the given name and colour on every event and to-do', () => {
    const feed = parseIcal(ics('todos.ics'), OCT, TPE, { name: '我的', color: '#ff0000' });
    expect(feed.events.map((e) => [e.calendar, e.color])).toEqual([['我的', '#ff0000']]);
    expect(new Set(feed.reminders.map((t) => t.list))).toEqual(new Set(['我的']));
  });

  it("leaves out the events the owner declined, each moved occurrence on its own", () => {
    const data = cal(
      'BEGIN:VEVENT', 'UID:a', 'SUMMARY:accepted', 'DTSTART:20261020T010000Z', 'ATTENDEE;PARTSTAT=ACCEPTED:mailto:Me@Gmail.com', 'END:VEVENT',
      'BEGIN:VEVENT', 'UID:b', 'SUMMARY:declined', 'DTSTART:20261021T010000Z', 'ATTENDEE;PARTSTAT=DECLINED:mailto:me@gmail.com', 'END:VEVENT',
      'BEGIN:VEVENT', 'UID:c', 'SUMMARY:weekly', 'DTSTART:20261005T010000Z', 'RRULE:FREQ=WEEKLY;COUNT=3', 'END:VEVENT',
      'BEGIN:VEVENT', 'UID:c', 'RECURRENCE-ID:20261012T010000Z', 'SUMMARY:weekly', 'DTSTART:20261012T010000Z', 'ATTENDEE;PARTSTAT=DECLINED:mailto:me@gmail.com', 'END:VEVENT',
    );
    const days = (owner?: string) => parseIcal(data, OCT, TPE, owner ? { owner } : {}).events.map((e) => `${e.title} ${e.start.slice(8, 10)}`).sort();
    expect(days('me@gmail.com')).toEqual(['accepted 20', 'weekly 05', 'weekly 19']);
    expect(days()).toHaveLength(5);
  });

  it('skips a broken or runaway event and keeps the rest', () => {
    const data = cal(
      'BEGIN:VEVENT', 'UID:bad', 'SUMMARY:bad', 'DTSTART:20261020T080000', 'RRULE:FREQ=SOMETIMES', 'END:VEVENT',
      'BEGIN:VEVENT', 'UID:often', 'SUMMARY:often', 'DTSTART;TZID=Asia/Taipei:19700101T070000', 'DURATION:PT10M', 'RRULE:FREQ=MINUTELY;INTERVAL=30', 'END:VEVENT',
      'BEGIN:VEVENT', 'UID:ok', 'SUMMARY:ok', 'DTSTART;VALUE=DATE:20261020', 'END:VEVENT',
    );
    const feed = parseIcal(data, OCT, TPE);
    expect(feed.events.map((e) => e.title)).toEqual(['ok']);
    expect(feed.skipped).toBe(2);
  });

  it.each(['', '<html>not a calendar</html>', 'BEGIN:VCARD\r\nEND:VCARD\r\n'])('refuses data that is not a calendar: %j', (data) => {
    expect(() => parseIcal(data, OCT, TPE)).toThrow(ICalError);
  });
});
