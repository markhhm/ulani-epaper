import { describe, expect, it } from 'vitest';
import tables from '../../shared/dither/natural-tables.json';
import { packIndices, previewFrame } from '../src/core/frame';
import { PANEL_RGB } from '../src/core/palette';
import { previewImage } from '../src/core/preview';
import { HEIGHT, WIDTH } from '../src/core/protocol';
import { toHexString } from './vectors';

const BLACK = 0;
const WHITE = 1;

/** Linear light of palette colour `index`, channel `c`. */
const linear = (index: number, c: number) => Number(tables.pal_lin[index]![c]);

/** The sRGB byte of linear light `v`, computed directly. */
const encode = (v: number) => Math.round(255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055));

const pixel = (image: { width: number; data: Uint8ClampedArray }, x: number, y: number) => {
  const o = (y * image.width + x) * 4;
  return [...image.data.subarray(o, o + 4)];
};

describe('previewImage', () => {
  it('averages in linear light when it shrinks: black and white make the light grey the eye sees', () => {
    const out = previewImage({ width: 2, height: 1, indices: Uint8Array.of(BLACK, WHITE) }, 1, 1);
    const [r, g, b, a] = pixel(out, 0, 0);
    const expected = [0, 1, 2].map((c) => encode((linear(BLACK, c) + linear(WHITE, c)) / 2));
    [r, g, b].forEach((value, c) => expect(Math.abs(value! - expected[c]!), `channel ${c}`).toBeLessThanOrEqual(1));
    expect(a).toBe(255);
    // Far lighter than the average of the sRGB numbers, which would show the grain too dark.
    const srgbAverage = (PANEL_RGB[BLACK]![1] + PANEL_RGB[WHITE]![1]) / 2;
    expect(g!).toBeGreaterThan(srgbAverage + 20);
  });

  it('keeps a flat colour exactly, at any shrink', () => {
    for (let index = 0; index < 7; index++) {
      const indices = new Uint8Array(WIDTH * HEIGHT).fill(index);
      for (const [w, h] of [[400, 240], [333, 200], [101, 61], [1, 1]] as const) {
        const out = previewImage({ width: WIDTH, height: HEIGHT, indices }, w, h);
        expect(pixel(out, w - 1, h - 1), `${index} at ${w} x ${h}`).toEqual([...PANEL_RGB[index]!, 255]);
        expect(pixel(out, 0, 0)).toEqual([...PANEL_RGB[index]!, 255]);
      }
    }
  });

  it('gives each preview pixel the average of the frame pixels it covers', () => {
    // Columns: black, white, white, black... shrunk 4:1 across and 1:1 down -> one black in four.
    const indices = Uint8Array.from({ length: 8 * 2 }, (_, i) => (i % 4 === 0 ? BLACK : WHITE));
    const out = previewImage({ width: 8, height: 2, indices }, 2, 1);
    const expected = [0, 1, 2].map((c) => encode((linear(BLACK, c) + 3 * linear(WHITE, c)) / 4));
    for (const x of [0, 1]) {
      pixel(out, x, 0).slice(0, 3).forEach((value, c) => expect(Math.abs(value - expected[c]!)).toBeLessThanOrEqual(1));
    }
  });

  it('enlarges with nearest neighbour, so each dot stays one ink', () => {
    const out = previewImage({ width: 2, height: 1, indices: Uint8Array.of(BLACK, WHITE) }, 4, 2);
    for (const y of [0, 1]) {
      expect([pixel(out, 0, y), pixel(out, 1, y)]).toEqual([[...PANEL_RGB[BLACK]!, 255], [...PANEL_RGB[BLACK]!, 255]]);
      expect([pixel(out, 2, y), pixel(out, 3, y)]).toEqual([[...PANEL_RGB[WHITE]!, 255], [...PANEL_RGB[WHITE]!, 255]]);
    }
  });

  it('shows a frame at its own size exactly as previewFrame does', () => {
    const indices = Uint8Array.from({ length: WIDTH * HEIGHT }, (_, i) => (i * 7 + Math.floor(i / WIDTH)) % 7);
    const out = previewImage({ width: WIDTH, height: HEIGHT, indices }, WIDTH, HEIGHT);
    // Compared as one string: a failing toEqual on 1.5 million numbers takes minutes to print.
    expect(toHexString(new Uint8Array(out.data.buffer))).toBe(toHexString(new Uint8Array(previewFrame(packIndices(indices)).data.buffer)));
    const twice = previewImage({ width: WIDTH, height: HEIGHT, indices }, 2 * WIDTH, 2 * HEIGHT);
    expect(pixel(twice, 2 * 123 + 1, 2 * 45 + 1)).toEqual(pixel(out, 123, 45));
  });

  it('draws indices without a palette colour as the black of the panel', () => {
    const out = previewImage({ width: 2, height: 1, indices: Uint8Array.of(9, 200) }, 2, 1);
    expect([pixel(out, 0, 0), pixel(out, 1, 0)]).toEqual([[...PANEL_RGB[BLACK]!, 255], [...PANEL_RGB[BLACK]!, 255]]);
  });

  it('rejects sizes that are not whole pixels or do not match the indices', () => {
    const source = { width: 2, height: 1, indices: Uint8Array.of(0, 1) };
    expect(() => previewImage(source, 1.5, 1)).toThrow(RangeError);
    expect(() => previewImage(source, -1, 1)).toThrow(RangeError);
    expect(() => previewImage({ ...source, width: 3 }, 1, 1)).toThrow(RangeError);
    expect(previewImage(source, 0, 0).data).toHaveLength(0);
  });

  it('shrinks a whole frame quickly', () => {
    const indices = Uint8Array.from({ length: WIDTH * HEIGHT }, (_, i) => (i * 2654435761) % 7);
    let start = performance.now();
    previewImage({ width: WIDTH, height: HEIGHT, indices }, 517, 310);
    const first = performance.now() - start;
    start = performance.now();
    previewImage({ width: WIDTH, height: HEIGHT, indices }, 517, 310);
    const second = performance.now() - start;
    console.info(`preview 800x480 -> 517x310: ${first.toFixed(1)} ms first call, ${second.toFixed(1)} ms after`);
    expect(first).toBeLessThan(500);
  });
});
