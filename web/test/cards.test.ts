import { describe, expect, it } from 'vitest';
import { cleanText, MAX_TEXT, MAX_TEXTS, newCardId, normalizeText, parseCard, textLength, type Card } from '../src/core/cards';

const fixtures = import.meta.glob<Card>('../../shared/layouts/card/*.json', { eager: true, import: 'default' });

const minimal = (extra: object = {}) => ({
  version: 1,
  id: 'a1b2c3d4',
  background: { color: 'yellow' },
  texts: [{ text: '開會中', box: [0.05, 0.12, 0.9, 0.45] }],
  ...extra,
});

describe('the card format (shared/CARDS.md)', () => {
  it('reads the three shared fixtures and writes them back as they are', () => {
    const paths = Object.keys(fixtures);
    expect(paths.length).toBe(3);
    for (const [path, json] of Object.entries(fixtures)) {
      const card = parseCard(JSON.parse(JSON.stringify(json)));
      // Fields the fixture leaves out are filled with their defaults.
      for (const text of card.texts) expect(text.outline_color).toBeDefined();
      expect(card.id, path).toBe(json.id);
      expect(parseCard(JSON.parse(JSON.stringify(card)))).toEqual(card);
    }
  });

  it('fills the defaults of everything left out', () => {
    const card = parseCard(minimal());
    expect(card.texts[0]).toEqual({
      text: '開會中',
      box: [0.05, 0.12, 0.9, 0.45],
      size: 48,
      color: 'black',
      outline: false,
      outline_color: 'white',
      align: 'center',
    });
    expect(parseCard(minimal({ background: {} })).background).toEqual({ color: 'white' });
    expect(parseCard(minimal({ background: { image: 'bg.jpg', crop: null } })).background).toEqual({ image: 'bg.jpg', crop: null });
  });

  it('normalises the text: NFC, line breaks, trimmed', () => {
    expect(normalizeText('  Café\r\nline two\r  ')).toBe('Café\nline two');
    expect(parseCard(minimal({ texts: [{ text: ' hi ', box: [0, 0, 1, 1] }] })).texts[0]?.text).toBe('hi');
  });

  it('refuses a card that breaks the rules, without repairing it', () => {
    const box = [0, 0, 0.5, 0.5];
    const bad: [string, unknown][] = [
      ['unknown version', minimal({ version: 2 })],
      ['short id', minimal({ id: 'a1b2' })],
      ['upper-case id', minimal({ id: 'A1B2C3D4' })],
      ['unknown colour', minimal({ background: { color: 'pink' } })],
      ['a path as background', minimal({ background: { image: '../x.jpg', crop: null } })],
      ['a gif background', minimal({ background: { image: 'x.gif', crop: null } })],
      ['crop outside the photo', minimal({ background: { image: 'x.jpg', crop: [0.5, 0, 1, 0.5] } })],
      ['too many boxes', minimal({ texts: Array.from({ length: MAX_TEXTS + 1 }, () => ({ text: 'a', box })) })],
      ['empty text', minimal({ texts: [{ text: '  ', box }] })],
      ['text over 80 characters', minimal({ texts: [{ text: 'x'.repeat(MAX_TEXT + 1), box }] })],
      ['box leaves the screen', minimal({ texts: [{ text: 'a', box: [0.5, 0, 0.6, 0.5] }] })],
      ['box without size', minimal({ texts: [{ text: 'a', box: [0, 0, 0, 0.5] }] })],
      ['font size 11', minimal({ texts: [{ text: 'a', box, size: 11 }] })],
      ['font size 241', minimal({ texts: [{ text: 'a', box, size: 241 }] })],
      ['fractional font size', minimal({ texts: [{ text: 'a', box, size: 20.5 }] })],
      ['unknown ink', minimal({ texts: [{ text: 'a', box, color: 'purple' }] })],
      ['unknown outline colour', minimal({ texts: [{ text: 'a', box, outline_color: 'grey' }] })],
      ['outline as a word', minimal({ texts: [{ text: 'a', box, outline: 'yes' }] })],
      ['unknown alignment', minimal({ texts: [{ text: 'a', box, align: 'justify' }] })],
      ['not an object', 42],
    ];
    for (const [name, json] of bad) expect(() => parseCard(json), name).toThrow();
  });

  it('accepts the limits themselves', () => {
    const box = [0.1, 0.1, 0.9, 0.9];
    const texts = Array.from({ length: MAX_TEXTS }, () => ({ text: 'x'.repeat(MAX_TEXT), box, size: 240 }));
    expect(parseCard(minimal({ texts })).texts).toHaveLength(MAX_TEXTS);
    expect(parseCard(minimal({ texts: [{ text: 'a', box, size: 12 }] })).texts).toHaveLength(1);
  });

  it('counts characters, not UTF-16 units, against the limit of 80', () => {
    const box = [0, 0, 1, 1];
    expect(parseCard(minimal({ texts: [{ text: '😀'.repeat(MAX_TEXT), box }] })).texts).toHaveLength(1);
    expect(() => parseCard(minimal({ texts: [{ text: '😀'.repeat(MAX_TEXT + 1), box }] }))).toThrow();
    expect(textLength('a😀b')).toBe(3);
  });

  it('makes ids of 8 lower-case hex characters that avoid the saved ones', () => {
    const taken = new Set<string>();
    for (let i = 0; i < 50; i++) {
      const id = newCardId(taken);
      expect(id).toMatch(/^[0-9a-f]{8}$/);
      expect(taken.has(id)).toBe(false);
      taken.add(id);
    }
  });
});

describe('text as the card can draw it', () => {
  it('drops emoji and invisible characters, keeps Chinese, Latin and symbols', () => {
    expect(cleanText('開會中 🙂👍🏽')).toBe('開會中');
    expect(cleanText('Café ❤️ ★ ©')).toBe('Café ★ ©');
    expect(cleanText('a‍b')).toBe('ab');
  });

  it('turns line breaks and tabs into spaces and folds runs of spaces', () => {
    expect(cleanText(' a \t b\nc  ')).toBe('a b c');
    expect(cleanText('🙂')).toBe('');
  });
});
