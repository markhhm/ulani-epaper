import { describe, expect, it } from 'vitest';
import { type AgendaData, dayNumber, fixedZone, parseAgenda } from '../src/core/agenda';
import { renderCalendarPage } from '../src/core/calendarPages';
import { CALENDAR_KINDS, type CalendarKind } from '../src/core/pages';
import { COLOURS } from '../src/core/palette';
import { testFace } from './calendarFace';

const fixtureFiles = import.meta.glob<Fixture>('../../shared/layouts/agenda/*.json', { eager: true, import: 'default' });
const goldenTexts = import.meta.glob<string>('../../shared/layouts/agenda/golden/*.txt', { eager: true, query: '?raw', import: 'default' });

interface Fixture {
  today: string;
  utc_offset: string;
  events: { title: string; start: string; end: string; all_day: boolean; calendar: string; location: string; color: string }[];
  tasks: { title: string; due: string | null; list_name: string; notes: string }[];
  fetched_at: string | null;
  background?: unknown;
}

const face = testFace();

/** A shared fixture (the Python `AgendaData` JSON) in the payload format, drawn on `today`. */
function load(name: string): { data: AgendaData; today: number; photo: boolean } {
  const f = fixtureFiles[`../../shared/layouts/agenda/${name}.json`] as Fixture;
  const [h, m] = f.utc_offset.slice(1).split(':').map(Number) as [number, number];
  const zone = fixedZone((f.utc_offset.startsWith('-') ? -1 : 1) * (h * 60 + m));
  const payload = {
    v: 1,
    events: f.events.map((e) => ({ ...e, allDay: e.all_day })),
    reminders: f.tasks.map((t) => ({ title: t.title, due: t.due, list: t.list_name, notes: t.notes })),
  };
  const [y, mo, d] = f.today.split('-').map(Number) as [number, number, number];
  return { data: parseAgenda(payload, zone, f.fetched_at ? Date.parse(f.fetched_at) : undefined), today: dayNumber(y, mo, d), photo: 'background' in f };
}

/** A stand-in for the dithered photo: stripes of green and blue. */
function stripes(): Uint8Array {
  return Uint8Array.from({ length: 800 * 480 }, (_, i) => (Math.floor(i / 800 / 8) % 2 ? COLOURS.green.index : COLOURS.blue.index));
}

const names = ['sample', 'empty', 'busy', 'midday', 'photo'];

describe('the shared calendar goldens', () => {
  it('has the five fixtures and a text golden for each of the five pages', () => {
    expect(Object.keys(fixtureFiles).length).toBe(5);
    expect(Object.keys(goldenTexts).length).toBe(25);
    expect([...CALENDAR_KINDS].sort()).toEqual(['agenda', 'day', 'month', 'monthgrid', 'todo']);
  });

  for (const name of names) {
    it.each(CALENDAR_KINDS)(`draws the same strings as Python for ${name}, page %s`, (kind) => {
      const { data, today, photo } = load(name);
      const expected = goldenTexts[`../../shared/layouts/agenda/golden/${kind}_${name}.txt`] as string;
      const { texts } = renderCalendarPage(kind, data, today, face, photo ? stripes() : null);
      expect(texts.join('\n') + '\n').toBe(expected);
    });
  }
});

describe('the pictures', () => {
  const render = (kind: CalendarKind, name = 'sample', background: Uint8Array | null = null) => {
    const { data, today } = load(name);
    return renderCalendarPage(kind, data, today, face, background).indices;
  };

  it.each(CALENDAR_KINDS)('is 800 x 480 panel colours only, the same every time, for %s', (kind) => {
    for (const name of names) {
      const one = render(kind, name);
      expect(one.length).toBe(800 * 480);
      expect(one.every((i) => i <= 6)).toBe(true);
      expect(Buffer.from(render(kind, name)).equals(Buffer.from(one))).toBe(true);
      expect(render(kind, name, stripes()).every((i) => i <= 6)).toBe(true);
    }
  });

  it('leaves no ink below y = 462', () => {
    for (const kind of CALENDAR_KINDS) {
      for (const name of names) {
        const below = render(kind, name).subarray(463 * 800);
        expect(below.every((i) => i === COLOURS.white.index), `${kind} ${name}`).toBe(true);
      }
    }
  });

  it('draws the weekday red on white, and white with a black outline on a photo', () => {
    const at = (indices: Uint8Array, x: number, y: number) => indices[y * 800 + x];
    // 星期一 sits at x 28.., baseline 56, 26 px: the test font's boxes reach 18 px above it
    const plain = render('month');
    expect([at(plain, 40, 50), at(plain, 26, 50)]).toEqual([COLOURS.red.index, COLOURS.white.index]);
    const photo = render('month', 'sample', stripes());
    expect([at(photo, 40, 50), at(photo, 26, 50)]).toEqual([COLOURS.white.index, COLOURS.black.index]);
    expect(at(photo, 600, 20)).not.toBe(COLOURS.white.index); // the photo shows between the texts
  });
});

describe('long and odd months and lists', () => {
  const zone = fixedZone(480);
  const drawn = (kind: CalendarKind, raw: object, y: number, m: number, d: number) =>
    renderCalendarPage(kind, parseAgenda({ v: 1, ...raw }, zone, Date.UTC(y, m - 1, d)), dayNumber(y, m, d), face).texts;

  it('shows the days of 4, 5 and 6 week months (February 2026, October 2026, August 2026)', () => {
    for (const [m, days] of [[2, 28], [10, 31], [8, 31]] as const) {
      const days1 = drawn('month', {}, 2026, m, 10).filter((t) => /^\d{1,2}$/.test(t));
      expect(days1.slice(-days)).toEqual(Array.from({ length: days }, (_, i) => String(i + 1)));
    }
  });

  it('puts 200 tasks in sections, each with its count and what is left over', () => {
    const reminders = Array.from({ length: 200 }, (_, i) => ({ title: `任務 ${i}`, due: i % 4 === 0 ? null : `2026-10-${String(1 + (i % 28)).padStart(2, '0')}` }));
    const texts = drawn('todo', { reminders }, 2026, 10, 12);
    expect(texts.slice(0, 2)).toEqual(['待辦事項', '200']);
    for (const section of ['逾期', '今天', '之後', '未排定']) expect(texts).toContain(section);
    expect(texts.filter((t) => /^還有 \d+ 項$/.test(t)).length).toBeGreaterThanOrEqual(3);
  });

  it('names an untitled event and one with nothing drawable', () => {
    const events = [
      { title: '  ', start: '2026-10-12T09:00:00+08:00', end: '2026-10-12T10:00:00+08:00' },
      { title: '🎂🎉', start: '2026-10-12T11:00:00+08:00', end: '2026-10-12T12:00:00+08:00' },
    ];
    const texts = drawn('day', { events }, 2026, 10, 12);
    expect(texts).toContain('（無標題）');
    expect(texts).toContain('（無法顯示的標題）');
  });

  it('cuts a 300 character title to its box with an ellipsis', () => {
    const events = [{ title: '很長的標題'.repeat(60), start: '2026-10-12T09:00:00+08:00', end: '2026-10-12T10:00:00+08:00' }];
    const long = drawn('day', { events }, 2026, 10, 12).find((t) => t.startsWith('很長'));
    expect(long?.endsWith('…')).toBe(true);
    expect((long ?? '').length).toBeLessThan(40);
  });
});
