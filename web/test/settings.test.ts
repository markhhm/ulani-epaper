import { describe, expect, it } from 'vitest';
import { DEFAULT_PAGES, suggestedPhotoSlot } from '../src/core/pages';
import { defaultSettings, GRAIN_LEVELS, parseSettings, setPageKind } from '../src/core/settings';

describe('settings', () => {
  it('start with the default page plan, standard grain and nothing sent', () => {
    expect(defaultSettings()).toEqual({ pages: DEFAULT_PAGES, grain: 1, lastSent: {}, lastBackup: null });
  });

  it('offer the four grain levels of the other apps', () => {
    expect(GRAIN_LEVELS.map((g) => [g.key, g.strength])).toEqual([['standard', 1], ['soft', 0.8], ['softer', 0.65], ['smoothest', 0.5]]);
  });

  it('are read back as written, and unknown fields are ignored', () => {
    const settings = { pages: { 1: 'card', 2: 'card', 3: 'photo', 4: 'day' }, grain: 0.8, lastSent: { 1: 'abcd1234' }, lastBackup: '2026-10-12T08:00:00.000Z' };
    expect(parseSettings(JSON.parse(JSON.stringify({ ...settings, future: true })))).toEqual(settings);
  });

  it('fill what is missing from the defaults', () => {
    expect(parseSettings({ pages: { 2: 'card' } })).toEqual({ ...defaultSettings(), pages: { ...DEFAULT_PAGES, 2: 'card' } });
    expect(parseSettings({})).toEqual(defaultSettings());
  });

  it('refuse values that cannot be right', () => {
    for (const bad of [
      { pages: { 1: 'poster' } },
      { pages: { 5: 'card' } },
      { grain: 0 },
      { grain: 1.5 },
      { grain: 'soft' },
      { lastSent: { 1: 42 } },
      { lastSent: { 7: 'abcd1234' } },
      { lastBackup: 'yesterday' },
    ]) {
      expect(() => parseSettings(bad), JSON.stringify(bad)).toThrow();
    }
    expect(() => parseSettings(null)).toThrow();
  });

  it('forget what was sent to a page whose kind changes', () => {
    const settings = { ...defaultSettings(), pages: { ...DEFAULT_PAGES, 2: 'card' as const }, lastSent: { 2: 'aaaaaaaa', 4: 'bbbbbbbb' } };
    const next = setPageKind(settings, 2, 'photo');
    expect(next.pages[2]).toBe('photo');
    expect(next.lastSent).toEqual({ 4: 'bbbbbbbb' });
    expect(setPageKind(settings, 2, 'card')).toEqual(settings);
  });
});

describe('the page offered for photos', () => {
  it('is page 4, or the first page that is not a card page', () => {
    expect(suggestedPhotoSlot({ 1: 'month', 2: 'agenda', 3: 'todo', 4: 'photo' })).toBe(4);
    expect(suggestedPhotoSlot({ 1: 'month', 2: 'agenda', 3: 'todo', 4: 'card' })).toBe(1);
    expect(suggestedPhotoSlot({ 1: 'card', 2: 'card', 3: 'card', 4: 'card' })).toBe(4);
  });
});
