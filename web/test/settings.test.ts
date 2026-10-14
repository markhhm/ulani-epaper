import { describe, expect, it } from 'vitest';
import { DEFAULT_PAGES, PAGE_KINDS } from '../src/core/pages';
import { COLOUR_MODES, defaultSettings, GRAIN_LEVELS, parseSettings, setColours, setPageKind } from '../src/core/settings';

describe('settings', () => {
  it('start with the default page plan, Natural colours, standard grain and nothing sent', () => {
    expect(defaultSettings()).toEqual({ pages: DEFAULT_PAGES, colours: 'natural', grain: 1, lastSent: {}, lastBackup: null, backgrounds: {} });
  });

  it('offer Natural, then Classic colours', () => {
    expect(COLOUR_MODES).toEqual(['natural', 'classic']);
  });

  it('offer the four grain levels of the other apps', () => {
    expect(GRAIN_LEVELS.map((g) => [g.key, g.strength])).toEqual([['standard', 1], ['soft', 0.8], ['softer', 0.65], ['smoothest', 0.5]]);
  });

  it('are read back as written, and unknown fields are ignored', () => {
    const settings = {
      pages: { 1: 'card', 2: 'card', 3: 'photo', 4: 'day' },
      colours: 'classic',
      grain: 0.8,
      lastSent: { 1: 'abcd1234' },
      lastBackup: '2026-10-12T08:00:00.000Z',
      backgrounds: { 1: { image: 'page-1.jpg', crop: null }, 4: { image: 'page-4.jpg', crop: [0, 0.1, 1, 0.8] } },
    };
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
      { colours: 'vivid' },
      { colours: 'Natural' },
      { colours: null },
      { colours: 'classic', grain: 0 },
      { lastSent: { 1: 42 } },
      { lastSent: { 7: 'abcd1234' } },
      { lastBackup: 'yesterday' },
      { backgrounds: { 5: { image: 'page-5.jpg', crop: null } } },
      { backgrounds: { 1: { image: 'page-2.jpg', crop: null } } }, // the file is always page-<its own page>.jpg
      { backgrounds: { 1: { image: '../page-1.jpg', crop: null } } },
      { backgrounds: { 1: { image: 'page-1.jpg', crop: [0, 0, 2, 1] } } },
      { backgrounds: { 1: { image: 'page-1.jpg', crop: [0, 0, 1] } } },
      { backgrounds: { 1: 'page-1.jpg' } },
    ]) {
      expect(() => parseSettings(bad), JSON.stringify(bad)).toThrow();
    }
    expect(() => parseSettings(null)).toThrow();
  });

  it('load the colours and the grain as stored when the colours are there', () => {
    for (const colours of COLOUR_MODES) {
      for (const { strength } of GRAIN_LEVELS) {
        const settings = { ...defaultSettings(), colours, grain: strength };
        expect(parseSettings(JSON.parse(JSON.stringify(settings)))).toEqual(settings);
      }
    }
  });

  it('load settings saved before the colour choice as Natural at standard grain, once', () => {
    // Paperhue 0.3 kept only the grain: the upgrade is the rule for choosing 自然 (shared/DITHER.md).
    for (const { strength } of GRAIN_LEVELS) {
      const upgraded = parseSettings({ pages: { 2: 'card' }, grain: strength, lastSent: { 2: 'abcd1234' } });
      expect(upgraded).toEqual({ ...defaultSettings(), pages: { ...DEFAULT_PAGES, 2: 'card' }, lastSent: { 2: 'abcd1234' } });
      // Saved again, they now hold the colours and load as they are, a grain chosen later included.
      const chosen = { ...upgraded, grain: strength };
      expect(parseSettings(JSON.parse(JSON.stringify(chosen)))).toEqual(chosen);
    }
    expect(() => parseSettings({ grain: 5 })).toThrow(RangeError); // still checked
  });

  it('set the grain to standard when switching to Natural, and keep it when switching to Classic', () => {
    const classic = { ...defaultSettings(), colours: 'classic' as const, grain: 0.5 };
    expect(setColours(classic, 'natural')).toEqual({ ...classic, colours: 'natural', grain: 1 });
    const natural = { ...defaultSettings(), grain: 0.65 };
    expect(setColours(natural, 'classic')).toEqual({ ...natural, colours: 'classic' });
    // Choosing what is already chosen changes nothing, the grain included.
    expect(setColours(natural, 'natural')).toBe(natural);
    expect(setColours(classic, 'classic')).toBe(classic);
  });

  it('keep what is stored for a page whose kind changes away and back: its photo, crop, fit and card', () => {
    const settings = {
      ...defaultSettings(),
      pages: { ...DEFAULT_PAGES, 2: 'card' as const, 4: 'photo' as const },
      lastSent: { 2: 'aaaaaaaa', 4: 'bbbbbbbb' },
      backgrounds: { 2: { image: 'page-2.jpg', crop: [0, 0.1, 1, 0.8] as const }, 4: { image: 'page-4.jpg', crop: null, fit: 'contain' as const } },
    };
    for (const [page, away] of [[2, 'photo'], [2, 'month'], [4, 'card'], [4, 'todo']] as const) {
      const changed = setPageKind(settings, page, away);
      expect(changed.pages[page]).toBe(away);
      expect(changed.lastSent).toEqual(settings.lastSent);
      expect(changed.backgrounds).toEqual(settings.backgrounds);
      expect(setPageKind(changed, page, settings.pages[page])).toEqual(settings);
    }
    expect(setPageKind(settings, 2, 'card')).toEqual(settings);
  });

  it('keep the fit of a photo page that shows the whole photo, and refuse an unknown fit', () => {
    const backgrounds = { 4: { image: 'page-4.jpg', crop: null, fit: 'contain' } };
    expect(parseSettings({ backgrounds }).backgrounds).toEqual(backgrounds);
    expect(parseSettings({ backgrounds: { 4: { image: 'page-4.jpg', crop: null, fit: 'cover' } } }).backgrounds).toEqual({ 4: { image: 'page-4.jpg', crop: null } });
    expect(() => parseSettings({ backgrounds: { 4: { image: 'page-4.jpg', crop: null, fit: 'stretch' } } })).toThrow(RangeError);
  });
});

describe('the page kinds of the phone', () => {
  it('are the photo, the calendar kinds and the card: no notes pages', () => {
    expect(PAGE_KINDS).toEqual(['photo', 'month', 'agenda', 'todo', 'day', 'monthgrid', 'card']);
  });

  it('load a page saved as a notes board or a big message as a photo page without a photo, so nothing is sent to it', () => {
    const settings = parseSettings({ pages: { 1: 'month', 2: 'board', 3: 'message', 4: 'card' }, lastSent: { 4: 'abcd1234' } });
    expect(settings.pages).toEqual({ 1: 'month', 2: 'photo', 3: 'photo', 4: 'card' });
    expect(settings.backgrounds).toEqual({});
    expect(settings.lastSent).toEqual({ 4: 'abcd1234' });
  });
});
