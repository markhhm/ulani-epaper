import { describe, expect, it } from 'vitest';
import { type Card, parseCard } from '../src/core/cards';
import { fitBoxHeight, layoutCard, type Measure, outlineOffsets, outlineRadius, pixelBox } from '../src/core/cardLayout';
import metrics from './fixtures/card-metrics.json';

const cardFiles = import.meta.glob<unknown>('../../shared/layouts/card/*.json', { eager: true, import: 'default' });
const goldenTexts = import.meta.glob<string>('../../shared/layouts/card/golden/*.txt', { eager: true, query: '?raw', import: 'default' });

/** The bold font of the Python reference, recorded for the sizes the fixtures use (scripts/gen_card_metrics.py). */
const recorded: Measure = {
  width(text, size) {
    const table = (metrics.sizes as Record<string, { widths: Record<string, number> }>)[String(size)]?.widths;
    if (!table) throw new Error(`no recorded metrics for size ${size}`);
    return Array.from(text).reduce((sum, ch) => sum + (table[ch] ?? NaN), 0);
  },
  extent(size) {
    const entry = (metrics.sizes as Record<string, { above: number; below: number }>)[String(size)];
    if (!entry) throw new Error(`no recorded metrics for size ${size}`);
    return { above: entry.above, below: entry.below };
  },
};

/** Every character is as wide as the font size; 國 reaches 0.9 size above the baseline and 0.1 below. */
const square: Measure = {
  width: (text, size) => Array.from(text).length * size,
  extent: (size) => ({ above: Math.round(size * 0.9), below: Math.round(size * 0.1) }),
};

const card = (texts: object[], background: object = { color: 'white' }): Card =>
  parseCard({ version: 1, id: 'a1b2c3d4', background, texts });

describe('the shared card goldens', () => {
  const names = Object.keys(cardFiles).map((path) => /([^/]+)\.json$/.exec(path)?.[1] as string);

  it('has the three fixtures with their text lists', () => {
    expect(names.sort()).toEqual(['meme', 'quote', 'status']);
  });

  it.each(['meme', 'quote', 'status'])('draws the same strings as Python for %s', (name) => {
    const json = cardFiles[`../../shared/layouts/card/${name}.json`];
    const expected = goldenTexts[`../../shared/layouts/card/golden/card_${name}.txt`] as string;
    const lines = layoutCard(parseCard(json), recorded).map((line) => line.text);
    expect(lines.join('\n') + '\n').toBe(expected);
  });
});

describe('where the text goes', () => {
  it('rounds the box to pixels with halves up', () => {
    expect(pixelBox([0.05, 0.12, 0.9, 0.45])).toEqual({ x0: 40, y0: 58, x1: 760, y1: 274 });
    // 1/64 of 800 is 12.5 and 3/64 of 480 is 22.5: halves go up, not to the even neighbour
    expect(pixelBox([1 / 64, 3 / 64, 1 / 64, 1 / 64])).toEqual({ x0: 13, y0: 23, x1: 25, y1: 30 });
  });

  it('puts the first baseline below the box top and the next ones a line pitch lower', () => {
    const lines = layoutCard(
      card([{ text: '一\n二\n三', box: [0, 0.1, 1, 0.8], size: 40 }]),
      square,
    );
    const above = square.extent(40).above;
    expect(lines.map((l) => l.y)).toEqual([48 + above, 48 + above + 50, 48 + above + 100]);
    expect(lines.map((l) => [l.x, l.anchor])).toEqual([[400, 'center'], [400, 'center'], [400, 'center']]);
  });

  it('anchors left and right at the box edges and centre at their middle', () => {
    const at = (align: string) => layoutCard(card([{ text: 'a', box: [0.1, 0, 0.5, 0.5], align }]), square)[0];
    expect([at('left')?.x, at('left')?.anchor]).toEqual([80, 'left']);
    expect([at('right')?.x, at('right')?.anchor]).toEqual([480, 'right']);
    expect([at('center')?.x, at('center')?.anchor]).toEqual([280, 'center']);
  });

  it('keeps the outline inside the box', () => {
    // size 52: radius floor(52/16 + 0.5) = 3, so the area starts 3 px inside
    const line = layoutCard(card([{ text: 'a', box: [0.1, 0, 0.5, 0.5], size: 52, align: 'left', outline: true }]), square)[0];
    expect(line).toMatchObject({ x: 83, outline: 3, outlineColor: 'white' });
    expect(outlineRadius(52)).toBe(3);
    expect(outlineRadius(40)).toBe(3); // 2.5 rounds up
    expect(outlineRadius(12)).toBe(1);
    expect(outlineRadius(8)).toBe(1);
  });

  it('draws an outline in the offsets the reference uses', () => {
    expect(outlineOffsets(1)).toHaveLength(9);
    expect(outlineOffsets(3)).toHaveLength(37);
    expect(outlineOffsets(3)).not.toContainEqual([3, 2]);
    expect(outlineOffsets(3)).toContainEqual([3, 1]);
  });
});

describe('wrapping and cutting', () => {
  it('wraps to the width of the box, Latin words whole', () => {
    // 20 px per character, a 400 px box holds 20 characters
    const lines = layoutCard(card([{ text: 'Hello wonderful world of cards', box: [0, 0, 0.5, 1], size: 20 }]), square);
    expect(lines.map((l) => l.text)).toEqual(['Hello wonderful', 'world of cards']);
  });

  it('never starts a line with closing punctuation', () => {
    const lines = layoutCard(card([{ text: '你好嗎，我很好', box: [0, 0, 0.075, 1], size: 20 }]), square);
    expect(lines.map((l) => l.text)).toEqual(['你好', '嗎，我', '很好']);
  });

  it('cuts the last line with … when the box is too short for the text', () => {
    // 100 px high box, size 20: pitch 25, above 18, below 2: floor((100 - 20) / 25) + 1 = 4 lines
    const lines = layoutCard(card([{ text: '一二三四五六七八九十'.repeat(8), box: [0, 0, 0.25, 100 / 480], size: 20 }]), square);
    expect(lines).toHaveLength(4);
    expect(lines[3]?.text.endsWith('…')).toBe(true);
  });

  it('draws one line in a box that is too short for one', () => {
    const lines = layoutCard(card([{ text: 'abc\ndef', box: [0, 0, 1, 0.01], size: 40 }]), square);
    expect(lines.map((l) => l.text)).toEqual(['abc…']);
  });

  it('draws nothing for a text of characters the font lacks', () => {
    expect(layoutCard(card([{ text: '🙂🙂', box: [0, 0, 1, 1] }]), square)).toEqual([]);
  });
});

describe('a box as tall as its text', () => {
  const cases = [
    { text: 'abc', size: 40, outline: false, width: 1, y: 0.2 },
    { text: 'one\ntwo\nthree', size: 33, outline: true, width: 0.5, y: 0.1 },
    { text: '一二三四五六七八九十'.repeat(4), size: 24, outline: true, width: 0.4, y: 0 },
    { text: 'Hello wonderful world of cards', size: 61, outline: false, width: 0.7, y: 0.3 },
  ];

  it.each(cases)('shows every line of $text at size $size', ({ text, size, outline, width, y }) => {
    const height = fitBoxHeight({ text, size, outline }, width, y, square);
    expect(height).toBeGreaterThan(0);
    const bare = (h: number) =>
      layoutCard(card([{ text, size, outline, box: [0, y, width, h], align: 'left' }]), square).map((l) => l.text);
    const tall = bare(1 - y);
    expect(bare(height)).toEqual(tall);
    expect(tall.some((line) => line.endsWith('…'))).toBe(false);
  });

  it('is not much taller than the text and stops at the bottom of the screen', () => {
    expect(fitBoxHeight({ text: 'abc', size: 40, outline: false }, 1, 0, square) * 480).toBeLessThan(50);
    expect(fitBoxHeight({ text: 'abc', size: 40, outline: false }, 1, 0.95, square)).toBeCloseTo(0.05, 12);
  });
});
