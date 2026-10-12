import { describe, expect, it } from 'vitest';
import { STUCKI_DIVISOR, STUCKI_KERNEL, keepInRange, mapNearest, stucki, toIndices } from '../src/core/dither';
import { nearestIndex } from '../src/core/palette';
import { ditherVectors as dv, fromHex, indexDigits, panelImage, rgbHexImage } from './vectors';

describe('dither vectors', () => {
  it('use the same kernel and strengths', () => {
    expect(dv.version).toBe(1);
    expect(STUCKI_KERNEL.map((tap) => [...tap])).toEqual(dv.kernel);
    expect(STUCKI_DIVISOR).toBe(dv.divisor);
    expect(dv.strengths).toEqual([1, 0.8, 0.65, 0.5, 0]);
  });

  it('exercise both range rules', () => {
    const full = dv.images.flatMap((image) => image.results.filter((r) => r.strength === 1));
    expect(full.reduce((n, r) => n + r.lift, 0)).toBeGreaterThan(0);
    expect(full.reduce((n, r) => n + r.scale, 0)).toBeGreaterThan(0);
    expect(dv.images.map((image) => `${image.width}x${image.height}`)).toEqual(
      expect.arrayContaining(['1x1', '7x5', '40x30', '64x48']),
    );
  });
});

describe('keepInRange', () => {
  it('matches every range vector', () => {
    for (const vector of dv.keep_in_range) {
      expect(keepInRange(...vector.in), `in ${vector.in.join(', ')}`).toEqual(vector.out);
    }
  });

  it('leaves values in range alone', () => {
    expect(keepInRange(0, 128, 255)).toEqual([0, 128, 255]);
  });

  it('lifts, then scales, then clamps', () => {
    // lift = trunc(255 * 100 / 355) = 71 -> (-29, 371, 121); scale = 255 / 371
    // -> (trunc(-19.9), trunc(255.0), trunc(83.2)) -> clamped.
    expect(keepInRange(-100, 300, 50)).toEqual([0, 255, 83]);
    // A lift of zero still clamps.
    expect(keepInRange(-1, 10, 10)).toEqual([0, 10, 10]);
    expect(keepInRange(510, 255, 0)).toEqual([255, 127, 0]);
  });
});

describe('stucki', () => {
  for (const image of dv.images) {
    for (const result of image.results) {
      it(`matches ${image.name} at strength ${result.strength}`, () => {
        const picture = rgbHexImage(image.width, image.height, image.rgb);
        expect(indexDigits(stucki(picture, result.strength))).toBe(result.indices);
      });
    }
  }

  it('ignores alpha', () => {
    const image = dv.images.find((i) => i.name === '64x48 noise')!;
    const expected = image.results[0]!.indices;
    for (const alpha of [0, 77]) {
      expect(indexDigits(stucki(rgbHexImage(image.width, image.height, image.rgb, alpha)))).toBe(expected);
    }
  });

  it('uses strength 1 by default and does not change the picture', () => {
    const image = dv.images.find((i) => i.name === '64x48 extremes')!;
    const picture = rgbHexImage(image.width, image.height, image.rgb);
    const before = [...picture.data];
    expect(indexDigits(stucki(picture))).toBe(image.results.find((r) => r.strength === 1)!.indices);
    expect([...picture.data]).toEqual(before);
  });

  it('handles an empty picture', () => {
    expect(stucki({ width: 0, height: 0, data: new Uint8ClampedArray(0) })).toHaveLength(0);
  });

  it('rejects a bad strength or a size that does not match the data', () => {
    const picture = rgbHexImage(1, 1, '808080');
    for (const bad of [-0.1, 1.01, Number.NaN, Infinity]) expect(() => stucki(picture, bad)).toThrow(RangeError);
    expect(() => stucki({ width: 2, height: 2, data: new Uint8ClampedArray(12) })).toThrow(RangeError);
    expect(() => stucki({ width: 1.5, height: 2, data: new Uint8ClampedArray(12) })).toThrow(RangeError);
  });

  it('dithers a full panel picture well under a second', () => {
    // Deterministic noise plus gradients: a worst case for range handling.
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
    // The first call includes compiling the loop, as in the app.
    let start = performance.now();
    const indices = stucki(picture);
    const first = performance.now() - start;
    start = performance.now();
    stucki(picture);
    const second = performance.now() - start;
    expect(indices).toHaveLength(800 * 480);
    expect(indices.every((i) => i <= 6)).toBe(true);
    console.info(`stucki 800x480: ${first.toFixed(1)} ms first call, ${second.toFixed(1)} ms after`);
    expect(first).toBeLessThan(1000);
  });
});

describe('mapNearest', () => {
  it('equals Stucki at strength 0 on every vector picture', () => {
    for (const image of dv.images) {
      const nearest = image.results.find((r) => r.strength === 0)!.indices;
      expect(indexDigits(mapNearest(rgbHexImage(image.width, image.height, image.rgb))), image.name).toBe(nearest);
    }
  });

  it('maps each pixel by itself', () => {
    const picture = rgbHexImage(4, 1, '808080ffbe00ff0000050505', 0);
    expect([...mapNearest(picture)]).toEqual([6, 5, 4, 0]);
    expect([...mapNearest(picture)]).toEqual([
      nearestIndex(128, 128, 128),
      nearestIndex(255, 190, 0),
      nearestIndex(255, 0, 0),
      nearestIndex(5, 5, 5),
    ]);
  });
});

describe('toIndices', () => {
  const image = dv.images.find((i) => i.name === '40x30 colour ramp')!;
  const picture = rgbHexImage(image.width, image.height, image.rgb);
  const expected = (strength: number) => image.results.find((r) => r.strength === strength)!.indices;

  it('dithers at full strength by default', () => {
    expect(indexDigits(toIndices(picture))).toBe(expected(1));
    expect(indexDigits(toIndices(picture, { dither: true }))).toBe(expected(1));
  });

  it('passes the strength on', () => {
    expect(indexDigits(toIndices(picture, { strength: 0.65 }))).toBe(expected(0.65));
  });

  it('maps to the nearest colour without dithering', () => {
    expect(indexDigits(toIndices(picture, { dither: false }))).toBe(expected(0));
    expect(expected(0)).not.toBe(expected(1));
  });

  it('searches exactly, on full 8-bit channels, at decision boundaries', () => {
    const edges = dv.images.find((i) => i.name === '8x2 nearest colour boundaries')!;
    const nearest = edges.results.find((r) => r.strength === 0)!.indices;
    const bytes = fromHex(edges.rgb);
    expect(indexDigits(toIndices(rgbHexImage(edges.width, edges.height, edges.rgb), { dither: false }))).toBe(nearest);
    // The worked examples: blue beats green; the yellow / orange and white /
    // blue ties go to the lower index.
    expect(edges.rgb.slice(0, 18)).toBe('008081ffbe057f80ff');
    expect(nearest.slice(0, 3)).toBe('351');
    // Every pixel is one where a search with the low 2 bits of each channel
    // cleared would choose another colour.
    for (let i = 0; i < edges.width * edges.height; i++) {
      const [r, g, b] = [bytes[3 * i]!, bytes[3 * i + 1]!, bytes[3 * i + 2]!];
      expect(nearestIndex(r & ~3, g & ~3, b & ~3), `pixel ${i}`).not.toBe(nearestIndex(r, g, b));
      expect(nearestIndex(r, g, b)).toBe(parseInt(nearest[i]!, 16));
    }
  });

  it('rejects a bad strength', () => {
    expect(() => toIndices(picture, { strength: 2 })).toThrow(RangeError);
  });
});
