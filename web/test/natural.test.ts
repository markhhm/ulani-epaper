import { createHash } from 'node:crypto';
import { inflateRawSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import tables from '../../shared/dither/natural-tables.json';
import { STUCKI_DIVISOR, STUCKI_KERNEL } from '../src/core/dither';
import { bright, NATURAL_VERSION, natural, naturalTarget } from '../src/core/natural';
import { GRAIN_LEVELS } from '../src/core/settings';
import { fromHex, indexDigits, naturalVectors as nv, panelImage, rgbHexImage } from './vectors';

/** A C99 hex float such as `0x1.28068731a1952p-4` (JavaScript has no parser for them). */
function hexFloat(text: string): number {
  const match = /^(-?)0x([0-9a-f]+)(?:\.([0-9a-f]*))?p([+-]\d+)$/i.exec(text);
  if (!match) throw new Error(`not a hex float: ${text}`);
  const [, sign, whole, fraction = '', exponent] = match;
  // At most 53 significant bits, so the mantissa is exact as a double; the power of two scales it exactly.
  const value = Number(BigInt(`0x${whole}${fraction}`)) * 2 ** (Number(exponent) - 4 * fraction.length);
  return sign ? -value : value;
}

const sha256 = (bytes: Uint8Array): string => createHash('sha256').update(bytes).digest('hex');

/** `values` as little-endian binary64, one after the other. */
function packDoubles(values: readonly number[]): Uint8Array {
  const bytes = new Uint8Array(values.length * 8);
  const view = new DataView(bytes.buffer);
  values.forEach((value, i) => view.setFloat64(i * 8, value, true));
  return bytes;
}

/** An opaque RGBA picture of `rgb` (3 bytes per pixel). */
function rgbaOf(width: number, height: number, rgb: Uint8Array) {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let i = 0; i < width * height; i++) {
    data[4 * i] = rgb[3 * i];
    data[4 * i + 1] = rgb[3 * i + 1];
    data[4 * i + 2] = rgb[3 * i + 2];
    data[4 * i + 3] = 255;
  }
  return { width, height, data };
}

describe('natural tables', () => {
  it('parse to the doubles the vectors pin, from the decimal and the hex strings alike', () => {
    const numeric = Object.entries(tables).filter(([key, value]) => key !== 'about' && JSON.stringify(value).includes('"'));
    expect(numeric.map(([key]) => key).sort()).toEqual(Object.keys(nv.tables_sha256).sort());
    for (const [key, value] of numeric) {
      const strings = [value].flat(2) as string[];
      const parse = key.endsWith('_hex') ? hexFloat : Number;
      expect(sha256(packDoubles(strings.map(parse))), key).toBe(nv.tables_sha256[key]);
    }
  });

  it('hold the integer tables the spec lists', () => {
    expect(tables.palette_srgb).toEqual([[76, 63, 89], [255, 255, 255], [73, 151, 107], [87, 97, 161], [216, 95, 99], [254, 237, 116], [236, 126, 103]]);
    expect(tables.sectors).toEqual([[3, 4], [4, 6], [6, 5], [5, 2], [2, 3]]);
    expect(tables.stucki).toEqual(STUCKI_KERNEL.map((tap) => [...tap]));
    expect(tables.stucki_div).toBe(STUCKI_DIVISOR);
  });

  it('use the grain strengths of the app', () => {
    expect(nv.version).toBe(NATURAL_VERSION);
    expect(nv.strengths).toEqual(GRAIN_LEVELS.map((level) => level.strength));
  });
});

describe('natural step A', () => {
  for (const [mode, cuspMove] of [['Natural', true], ['Bright', false]] as const) {
    it(`matches every colour vector to the last bit, for ${mode}`, () => {
      expect(nv.colours.length).toBeGreaterThan(50);
      for (const vector of nv.colours) {
        const [r, g, b] = fromHex(vector.rgb);
        const expected = cuspMove ? vector.target : vector.bright_target;
        const { target, set } = naturalTarget(r!, g!, b!, cuspMove);
        expect(set, vector.name).toBe(cuspMove ? vector.set : vector.bright_set);
        expect(target, vector.name).toEqual(expected.map(hexFloat));
        // toEqual would let -0 equal 0; every bit counts here.
        target.forEach((value, k) => expect(Object.is(value, hexFloat(expected[k]!)), `${vector.name} channel ${k}`).toBe(true));
      }
    });
  }

  it('differs between Natural and Bright only where the cusp move works', () => {
    const moved = nv.colours.filter((v) => v.target.join() !== v.bright_target.join());
    expect(moved.length).toBeGreaterThan(10);
    expect(moved.length).toBeLessThan(nv.colours.length);
    expect(nv.colours.every((v) => v.set === v.bright_set)).toBe(true); // the move never changes the set
  });
});

describe('natural', () => {
  for (const image of nv.images) {
    it(`matches ${image.name} at every strength, Natural and Bright`, () => {
      const picture = rgbHexImage(image.width, image.height, image.rgb);
      expect(image.results.map((r) => r.strength)).toEqual(nv.strengths);
      expect(image.bright.map((r) => r.strength)).toEqual(nv.strengths);
      for (const result of image.results) {
        expect(indexDigits(natural(picture, result.strength)), `strength ${result.strength}`).toBe(result.indices);
      }
      for (const result of image.bright) {
        expect(indexDigits(bright(picture, result.strength)), `Bright, strength ${result.strength}`).toBe(result.indices);
      }
    });
  }

  for (const frame of nv.frames) {
    it(`matches the frame ${frame.name} at every strength, Natural and Bright`, () => {
      const rgb = new Uint8Array(inflateRawSync(Buffer.from(frame.rgb_deflate, 'base64')));
      expect(rgb).toHaveLength(frame.width * frame.height * 3);
      const picture = rgbaOf(frame.width, frame.height, rgb);
      expect(frame.results.map((r) => r.strength)).toEqual(nv.strengths);
      expect(frame.bright.map((r) => r.strength)).toEqual(nv.strengths);
      for (const result of frame.results) {
        const indices = natural(picture, result.strength);
        expect(indices).toHaveLength(frame.width * frame.height);
        expect(sha256(indices), `strength ${result.strength}`).toBe(result.sha256);
      }
      for (const result of frame.bright) {
        expect(sha256(bright(picture, result.strength)), `Bright, strength ${result.strength}`).toBe(result.sha256);
      }
    });
  }

  it('ignores alpha and does not change the picture', () => {
    const image = nv.images.find((i) => i.name === 'pastel picture shrunk to 64x40')!;
    const expected = image.results.find((r) => r.strength === 1)!.indices;
    for (const alpha of [0, 77, 255]) {
      const picture = rgbHexImage(image.width, image.height, image.rgb, alpha);
      const before = [...picture.data];
      expect(indexDigits(natural(picture))).toBe(expected);
      expect([...picture.data]).toEqual(before);
    }
  });

  it('handles an empty picture', () => {
    expect(natural({ width: 0, height: 0, data: new Uint8ClampedArray(0) })).toHaveLength(0);
  });

  it('rejects a bad strength or a size that does not match the data', () => {
    const picture = rgbHexImage(1, 1, '808080');
    for (const bad of [-0.1, 1.01, Number.NaN, Infinity]) {
      expect(() => natural(picture, bad)).toThrow(RangeError);
      expect(() => bright(picture, bad)).toThrow(RangeError);
    }
    expect(() => natural({ width: 2, height: 2, data: new Uint8ClampedArray(12) })).toThrow(RangeError);
    expect(() => natural({ width: 1.5, height: 2, data: new Uint8ClampedArray(12) })).toThrow(RangeError);
  });

  it('dithers a full panel picture well under a second', () => {
    // Deterministic noise plus gradients: nearly every pixel a new colour, the worst case for step A.
    let state = 0x2545f491;
    const noise = () => {
      state ^= state << 13;
      state ^= state >>> 17;
      state ^= state << 5;
      return (state >>> 0) & 0xff;
    };
    const picture = panelImage((x, y) => [(x * 255) / 799 + (noise() & 31) - 16, (y * 255) / 479, noise()].map(
      (c) => Math.max(0, Math.min(255, Math.round(c))),
    ) as [number, number, number]);
    // The first call includes compiling the loops, as in the app.
    let start = performance.now();
    const indices = natural(picture);
    const first = performance.now() - start;
    start = performance.now();
    natural(picture);
    const second = performance.now() - start;
    expect(indices).toHaveLength(800 * 480);
    expect(indices.every((i) => i <= 6)).toBe(true);
    console.info(`natural 800x480: ${first.toFixed(1)} ms first call, ${second.toFixed(1)} ms after`);
    expect(first).toBeLessThan(1000);
  });
});
