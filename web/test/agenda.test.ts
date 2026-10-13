import { describe, expect, it } from 'vitest';
import { accent, AgendaError, dayNumber, DAY, eventsOn, fixedZone, parseAgenda, sortedTasks, todayIn } from '../src/core/agenda';

const TPE = fixedZone(8 * 60);
const wall = (y: number, m: number, d: number, h = 0, min = 0) => Date.UTC(y, m - 1, d, h, min);
const payload = (events: unknown[] = [], reminders: unknown[] = []) => ({ v: 1, events, reminders });
const timed = (title: string, start: string, end: string) => ({ title, start, end, allDay: false, calendar: '個人' });
const allDay = (title: string, start: string, end: string) => ({ title, start, end, allDay: true, calendar: '節日' });

describe('reading the calendar payload', () => {
  it('turns a timed event into the wall clock of the zone', () => {
    const data = parseAgenda(payload([timed('早會', '2026-10-12T09:00:00+08:00', '2026-10-12T09:30:00+08:00')]), TPE);
    expect(data.events[0]).toMatchObject({ title: '早會', start: wall(2026, 10, 12, 9), end: wall(2026, 10, 12, 9, 30), allDay: false });
    // the same instant seen from New York (UTC-4 in October): the evening before
    const ny = parseAgenda(payload([timed('早會', '2026-10-12T09:00:00+08:00', '2026-10-12T09:30:00+08:00')]), fixedZone(-240));
    expect(ny.events[0]?.start).toBe(wall(2026, 10, 11, 21));
  });

  it('reads all-day events as dates with an exclusive end, however the end is written', () => {
    const cases: [string, string][] = [
      ['2026-10-13T00:00:00+08:00', '2026-10-14T00:00:00+08:00'], // next midnight
      ['2026-10-13T00:00:00+08:00', '2026-10-13T23:59:00+08:00'], // last minute of the last day
      ['2026-10-13', '2026-10-14'], // bare dates
      ['2026-10-13T00:00:00+08:00', '2026-10-13T00:00:00+08:00'], // end not after the start: one day
    ];
    for (const [start, end] of cases) {
      const data = parseAgenda(payload([allDay('國慶日', start, end)]), fixedZone(-480)); // another zone changes nothing
      expect(data.events[0]).toMatchObject({ allDay: true, start: wall(2026, 10, 13), end: wall(2026, 10, 14) });
    }
    expect(parseAgenda(payload([allDay('連假', '2026-10-10', '2026-10-13')]), TPE).events[0]?.end).toBe(wall(2026, 10, 13));
  });

  it('reads reminders: the due date, or none', () => {
    const data = parseAgenda(payload([], [{ title: '繳費', due: '2026-10-14T00:00:00+08:00' }, { title: '沒期限', due: null }]), TPE);
    expect(data.tasks).toEqual([
      { title: '繳費', due: dayNumber(2026, 10, 14), listName: '', notes: '' },
      { title: '沒期限', due: null, listName: '', notes: '' },
    ]);
  });

  it('keeps the optional place, colour, list and notes', () => {
    const data = parseAgenda(
      payload([{ ...timed('審查', '2026-10-12T10:00:00+08:00', '2026-10-12T11:30:00+08:00'), location: '3F', color: '#f83a22' }], [{ title: 't', list: '家務', notes: '電費' }]),
      TPE,
    );
    expect(data.events[0]).toMatchObject({ location: '3F', color: '#f83a22' });
    expect(data.tasks[0]).toMatchObject({ listName: '家務', notes: '電費' });
  });

  it('stamps when it was read, in the zone', () => {
    const now = Date.UTC(2026, 9, 12, 7, 0) - 8 * 3600_000; // 07:00 in Taipei
    expect(parseAgenda(payload(), TPE, now).fetchedAt).toBe(wall(2026, 10, 12, 7));
    expect(parseAgenda(payload(), TPE).fetchedAt).toBeNull();
  });

  it('skips an event it cannot read and refuses what is not a payload', () => {
    const data = parseAgenda(payload([{ title: 'x' }, 'text', timed('好', '2026-10-12T09:00:00+08:00', '2026-10-12T10:00:00+08:00'), allDay('壞日期', '10/13', '10/14')]), TPE);
    expect(data.events.map((e) => e.title)).toEqual(['好']);
    expect(() => parseAgenda({ v: 2, events: [] }, TPE)).toThrow(AgendaError);
    expect(() => parseAgenda('[]', TPE)).toThrow(AgendaError);
    expect(() => parseAgenda({ v: 1, events: 'x' }, TPE)).toThrow(AgendaError);
  });
});

describe('the days of a calendar', () => {
  const data = parseAgenda(
    payload([
      timed('午餐', '2026-10-12T12:00:00+08:00', '2026-10-12T13:00:00+08:00'),
      allDay('連假', '2026-10-10', '2026-10-13'),
      timed('早會', '2026-10-12T09:00:00+08:00', '2026-10-12T09:30:00+08:00'),
      timed('跨夜', '2026-10-13T22:00:00+08:00', '2026-10-14T02:00:00+08:00'),
      timed('提醒', '2026-10-14T00:00:00+08:00', '2026-10-14T00:00:00+08:00'), // zero length
    ]),
    TPE,
  );
  const titles = (y: number, m: number, d: number) => eventsOn(data, dayNumber(y, m, d)).map((e) => e.title);

  it('lists all-day events first, then by start; an all-day end is exclusive', () => {
    expect(titles(2026, 10, 12)).toEqual(['連假', '早會', '午餐']);
    expect(titles(2026, 10, 13)).toEqual(['跨夜']); // 連假 ended with the 12th
  });

  it('shows an event across midnight on both days, and a zero-length one only where it happens', () => {
    expect(titles(2026, 10, 14)).toEqual(['跨夜', '提醒']);
    expect(titles(2026, 10, 13)).not.toContain('提醒');
  });

  it('sorts open tasks by due date, undated last', () => {
    const tasks = parseAgenda(payload([], [{ title: '沒期限' }, { title: '下週', due: '2026-10-19' }, { title: '昨天', due: '2026-10-11' }]), TPE);
    expect(sortedTasks(tasks).map((t) => t.title)).toEqual(['昨天', '下週', '沒期限']);
  });

  it('knows today in a zone', () => {
    const instant = Date.UTC(2026, 9, 12, 17, 0); // 01:00 on the 13th in Taipei
    expect(todayIn(TPE, instant)).toBe(dayNumber(2026, 10, 13));
    expect(todayIn(fixedZone(0), instant)).toBe(dayNumber(2026, 10, 12));
    expect(dayNumber(1970, 1, 2)).toBe(1);
    expect(DAY).toBe(86_400_000);
  });
});

describe('accent', () => {
  it.each([
    ['#f83a22', 'red'], ['#ff7537', 'orange'], ['#fad165', 'yellow'], ['#16a765', 'green'], ['#4986e7', 'blue'],
    ['#cd74e6', 'blue'], ['#c2c2c2', 'black'], ['#616161', 'black'], ['#e67c73', 'red'], ['#f6bf26', 'yellow'],
  ])('maps the calendar colour %s to %s by hue', (colour, expected) => {
    expect(accent(colour)).toBe(expected);
  });

  it('falls back to black for a missing or bad colour', () => {
    for (const bad of ['', 'blue', '#12345', '#gggggg', undefined]) expect(accent(bad)).toBe('black');
  });
});
