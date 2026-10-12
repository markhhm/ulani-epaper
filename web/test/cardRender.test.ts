import { describe, expect, it } from 'vitest';
import { parseCard } from '../src/core/cards';
import { cardSig, type Mask, renderCardIndices, type TextRasterizer } from '../src/core/cardRender';
import { COLOURS } from '../src/core/palette';
import { HEIGHT, WIDTH } from '../src/core/protocol';

const BLACK = COLOURS.black.index;
const WHITE = COLOURS.white.index;
const RED = COLOURS.red.index;
const YELLOW = COLOURS.yellow.index;

/** Every character is a solid block 2 wide and 3 high, sitting on the baseline: simple to read back. */
const blocks: TextRasterizer = {
  width: (text) => Array.from(text).length * 2,
  extent: () => ({ above: 3, below: 0 }),
  mask(text): Mask {
    const width = Array.from(text).length * 2;
    return { width, height: 3, originX: 0, baseline: 3, ink: new Uint8Array(width * 3).fill(1) };
  },
};

/** One ink pixel, so an outline is exactly the offsets around it. */
const dot: TextRasterizer = {
  width: () => 1,
  extent: () => ({ above: 1, below: 0 }),
  mask: () => ({ width: 1, height: 1, originX: 0, baseline: 1, ink: Uint8Array.of(1) }),
};

const card = (texts: object[], background: object = { color: 'white' }) => parseCard({ version: 1, id: 'a1b2c3d4', background, texts });
const at = (indices: Uint8Array, x: number, y: number) => indices[y * WIDTH + x];
const count = (indices: Uint8Array, value: number) => indices.reduce((n, v) => n + (v === value ? 1 : 0), 0);

describe('drawing a card', () => {
  it('fills a plain colour, or copies the background it is given', () => {
    const plain = renderCardIndices(card([], { color: 'yellow' }), null, blocks);
    expect(plain).toHaveLength(WIDTH * HEIGHT);
    expect(count(plain, YELLOW)).toBe(WIDTH * HEIGHT);
    const photo = new Uint8Array(WIDTH * HEIGHT).fill(RED);
    const drawn = renderCardIndices(card([], { image: 'a1b2c3d4.jpg', crop: null }), photo, blocks);
    expect(drawn).toEqual(photo);
    expect(drawn).not.toBe(photo); // the background is kept for the next draw
  });

  it('puts the text in its ink with the baseline where the layout says', () => {
    // Box x 0.1 -> 80, y 0.1 -> 48; size 20: first baseline 48 + above (3).
    const out = renderCardIndices(card([{ text: 'ab', box: [0.1, 0.1, 0.5, 0.5], size: 20, align: 'left' }]), null, blocks);
    expect(at(out, 80, 48)).toBe(BLACK); // top-left of the block: rows 48..50 above the baseline 51
    expect(at(out, 83, 50)).toBe(BLACK); // 'ab' is 4 wide
    expect(at(out, 84, 50)).toBe(WHITE);
    expect(at(out, 80, 51)).toBe(WHITE);
    expect(count(out, BLACK)).toBe(4 * 3);
  });

  it('anchors the line at its left, centre or right', () => {
    // The box is x 80..480: left edge 80, centre 280 (the line is 4 wide: 278..281), right edge 480 (476..479).
    const line = (align: string) => renderCardIndices(card([{ text: 'ab', box: [0.1, 0.1, 0.5, 0.5], size: 20, align }]), null, blocks);
    expect(at(line('left'), 80, 49)).toBe(BLACK);
    expect(at(line('center'), 278, 49)).toBe(BLACK);
    expect(at(line('center'), 277, 49)).toBe(WHITE);
    expect(at(line('right'), 479, 49)).toBe(BLACK);
    expect(at(line('right'), 475, 49)).toBe(WHITE);
  });

  it('draws an outline in the reference offsets, then the text over it', () => {
    // size 48 -> radius 3: a single ink pixel gets the 37 offsets of radius 3, itself in the text colour
    const out = renderCardIndices(
      card([{ text: 'a', box: [0.2, 0.2, 0.5, 0.5], size: 48, color: 'white', outline: true, outline_color: 'red', align: 'left' }], { color: 'black' }),
      null,
      dot,
    );
    expect(count(out, RED)).toBe(36);
    expect(count(out, WHITE)).toBe(1);
    // box 160, 96 plus the outline radius 3 -> text pixel at x 163, baseline 99 + 1 above => y 99 + 0
    const x = 163;
    const y = 96 + 3 + 1 - 1;
    expect(at(out, x, y)).toBe(WHITE);
    expect(at(out, x + 3, y + 1)).toBe(RED);
    expect(at(out, x + 3, y + 2)).toBe(BLACK); // (3, 2) is outside the rounded square
    expect(at(out, x - 3, y - 1)).toBe(RED);
  });

  it('lets later boxes cover earlier ones', () => {
    const out = renderCardIndices(
      card([
        { text: 'ab', box: [0, 0, 0.5, 0.5], size: 20, color: 'red', align: 'left' },
        { text: 'ab', box: [0, 0, 0.5, 0.5], size: 20, color: 'yellow', align: 'left' },
      ]),
      null,
      blocks,
    );
    expect(at(out, 0, 0)).toBe(YELLOW);
    expect(count(out, RED)).toBe(0);
  });

  it('clips what hangs over the screen edge instead of wrapping it', () => {
    // A glyph that starts 5 px left of its origin (an overhang), at the left edge of the screen.
    const overhang: TextRasterizer = {
      width: () => 8,
      extent: () => ({ above: 3, below: 0 }),
      mask: () => ({ width: 8, height: 3, originX: 5, baseline: 3, ink: new Uint8Array(24).fill(1) }),
    };
    const out = renderCardIndices(card([{ text: 'a', box: [0, 0, 0.5, 0.5], size: 20, color: 'black', align: 'left' }]), null, overhang);
    expect(count(out, BLACK)).toBe(3 * 3); // columns 0..2 of the 3 rows
    expect(at(out, WIDTH - 1, 0)).toBe(WHITE);
    expect(at(out, WIDTH - 1, 1)).toBe(WHITE);
  });
});

describe('the fingerprint of a drawing', () => {
  const base = { version: 1, id: 'a1b2c3d4', background: { color: 'white' }, texts: [{ text: 'hi', box: [0, 0, 0.5, 0.5] }] };

  it('changes with whatever changes the picture, and with nothing else', () => {
    const sig = (card: object, grain = 1) => cardSig(parseCard({ ...base, ...card }), grain);
    expect(sig({})).toBe(sig({ id: 'ffffffff' }));
    expect(sig({})).not.toBe(sig({ background: { color: 'red' } }));
    expect(sig({})).not.toBe(sig({ texts: [{ text: 'ho', box: [0, 0, 0.5, 0.5] }] }));
    expect(sig({})).not.toBe(sig({ texts: [{ text: 'hi', box: [0, 0, 0.5, 0.5], outline: true }] }));
    expect(sig({})).not.toBe(sig({}, 0.8));
    const crop = (c: number[] | null) => sig({ background: { image: 'a1b2c3d4.jpg', crop: c } });
    expect(crop(null)).not.toBe(crop([0, 0, 1, 0.6]));
  });
});
