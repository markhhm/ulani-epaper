/**
 * Mapping pictures onto the seven panel colours, in one of two ways the user
 * chooses (「顏色」 / Colours, shared/DITHER.md): 自然 / Natural (the default,
 * natural.ts) or 經典 / Classic, the Stucki ditherer of this module.
 *
 * Classic uses Stucki error diffusion on the ideal palette, which looks
 * better on this panel than Floyd-Steinberg. The procedure is specified
 * exactly (integer arithmetic, truncation, range handling) so every
 * implementation produces the same indices for the same input:
 *
 * - Work on integer R, G, B per pixel, starting from the picture (alpha is
 *   ignored). Visit pixels in raster order (rows top to bottom, each row left
 *   to right).
 * - The pixel's index is palette.nearestIndex of its current value.
 * - The error is (current value - chosen colour) per channel.
 * - For each kernel tap (w, dx, dy) whose target (x + dx, y + dy) lies inside
 *   the picture, compute the factor `f = w / 42 * strength` (in that order,
 *   in floating point), add `trunc(error * f)` per channel to the target
 *   (truncation toward zero), then pass the target through keepInRange.
 *
 * Without dithering (mapNearest, toIndices with `dither: false`) each pixel
 * gets palette.nearestIndex of its own value: exactly Stucki at strength 0.
 * The search is exact, on full 8-bit channels. Colour quantizers that search
 * at reduced channel precision (for example 6 bits per channel) choose a
 * different colour for about 1 % of all colours, near the decision
 * boundaries; matching them is not a goal.
 *
 * shared/vectors/dither-vectors.json pins the expected indices; its strength 0
 * results are also the expected output without dithering, and its "nearest
 * colour boundaries" picture holds colours where the two searches differ.
 */

import type { RgbaImage } from './frame';
import { natural } from './natural';
import { PALETTE, nearestIndex } from './palette';

/** How photos are dithered: 自然 / Natural (natural.ts) or 經典 / Classic (stucki). */
export type ColourMode = 'natural' | 'classic';

/** One error diffusion tap: weight, column offset, row offset. */
export type KernelTap = readonly [weight: number, dx: number, dy: number];

/** Stucki kernel in raster order; the weights sum to STUCKI_DIVISOR. */
export const STUCKI_KERNEL: readonly KernelTap[] = Object.freeze([
  [8, 1, 0], [4, 2, 0],
  [2, -2, 1], [4, -1, 1], [8, 0, 1], [4, 1, 1], [2, 2, 1],
  [1, -2, 2], [2, -1, 2], [4, 0, 2], [2, 1, 2], [1, 2, 2],
] as const);

export const STUCKI_DIVISOR = 42;

export interface DitherOptions {
  /**
   * Diffuse the error (default true); false maps each pixel to its exact
   * nearest colour (mapNearest), the same as strength 0.
   */
  readonly dither?: boolean;
  /**
   * Share of the error to diffuse, 0-1 (default 1). Lower values give less
   * grain and more banding; 0 equals plain nearest colour.
   */
  readonly strength?: number;
  /** Natural (default) or Classic dithering; without dithering it is not used. */
  readonly colours?: ColourMode;
}

// Palette channels by index, for the per-pixel loop.
const PAL_R = Int32Array.from(PALETTE, (c) => c.rgb[0]);
const PAL_G = Int32Array.from(PALETTE, (c) => c.rgb[1]);
const PAL_B = Int32Array.from(PALETTE, (c) => c.rgb[2]);

// Output of rangeFix (avoids allocating in the per-pixel loop).
const fixed = new Int32Array(3);

/** keepInRange, writing its result into `fixed`. */
function rangeFix(r: number, g: number, b: number): void {
  const low = Math.min(r, g, b);
  if (low < 0) {
    const lift = Math.trunc((255 * -low) / (255 - low));
    r += lift;
    g += lift;
    b += lift;
  }
  const high = Math.max(r, g, b);
  if (high > 255) {
    const scale = 255 / high;
    r = Math.trunc(r * scale);
    g = Math.trunc(g * scale);
    b = Math.trunc(b * scale);
  }
  fixed[0] = r < 0 ? 0 : r > 255 ? 255 : r;
  fixed[1] = g < 0 ? 0 : g > 255 ? 255 : g;
  fixed[2] = b < 0 ? 0 : b > 255 ? 255 : b;
}

/**
 * Bring a pixel that collected too much error back into 0-255 while keeping
 * its hue, in this order:
 * 1. If the lowest channel `low` is negative, add
 *    `trunc(255 * -low / (255 - low))` to all three channels.
 * 2. If then the highest channel `high` exceeds 255, compute
 *    `scale = 255 / high` and replace each channel `c` by `trunc(c * scale)`.
 * 3. Clamp each channel to 0-255.
 *
 * Inputs are integers.
 */
export function keepInRange(r: number, g: number, b: number): [number, number, number] {
  rangeFix(r, g, b);
  return [fixed[0], fixed[1], fixed[2]];
}

function checkImage(image: RgbaImage): number {
  const { width, height, data } = image;
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 0 || height < 0) {
    throw new RangeError(`image size must be whole pixels, got ${width} x ${height}`);
  }
  const pixels = width * height;
  if (data.length !== pixels * 4) {
    throw new RangeError(`a ${width} x ${height} RGBA image has ${pixels * 4} bytes, got ${data.length}`);
  }
  return pixels;
}

function checkStrength(strength: number): void {
  if (!(strength >= 0 && strength <= 1)) {
    throw new RangeError(`strength must be 0-1, got ${strength}`);
  }
}

/**
 * Palette indices (one byte per pixel, row-major) of `image` with Stucki error
 * diffusion as described at the top of this module.
 *
 * @param strength share of the error to diffuse, 0-1 (default 1).
 * @throws RangeError when `strength` is outside 0-1 or `data` does not match the size.
 */
export function stucki(image: RgbaImage, strength = 1): Uint8Array {
  const pixels = checkImage(image);
  checkStrength(strength);
  const { width, height, data } = image;

  // Working copy of the picture; every value stays an integer in 0-255
  // because each update goes through the range handling.
  const r = new Int32Array(pixels);
  const g = new Int32Array(pixels);
  const b = new Int32Array(pixels);
  for (let i = 0, o = 0; i < pixels; i++, o += 4) {
    r[i] = data[o];
    g[i] = data[o + 1];
    b[i] = data[o + 2];
  }

  const taps = STUCKI_KERNEL.length;
  const factor = new Float64Array(taps);
  const dxs = new Int32Array(taps);
  const dys = new Int32Array(taps);
  STUCKI_KERNEL.forEach(([w, dx, dy], k) => {
    factor[k] = (w / STUCKI_DIVISOR) * strength;
    dxs[k] = dx;
    dys[k] = dy;
  });

  const out = new Uint8Array(pixels);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = y * width + x;
      const pr = r[i];
      const pg = g[i];
      const pb = b[i];
      const best = nearestIndex(pr, pg, pb);
      out[i] = best;
      const er = pr - PAL_R[best];
      const eg = pg - PAL_G[best];
      const eb = pb - PAL_B[best];
      // With no error every target keeps its (in-range) value.
      if (er === 0 && eg === 0 && eb === 0) continue;
      for (let k = 0; k < taps; k++) {
        const xx = x + dxs[k];
        const yy = y + dys[k];
        if (xx < 0 || xx >= width || yy >= height) continue;
        const j = yy * width + xx;
        const f = factor[k];
        const nr = r[j] + Math.trunc(er * f);
        const ng = g[j] + Math.trunc(eg * f);
        const nb = b[j] + Math.trunc(eb * f);
        if ((nr | ng | nb) >= 0 && nr <= 255 && ng <= 255 && nb <= 255) {
          // Already in range: keepInRange would return it unchanged.
          r[j] = nr;
          g[j] = ng;
          b[j] = nb;
        } else {
          rangeFix(nr, ng, nb);
          r[j] = fixed[0];
          g[j] = fixed[1];
          b[j] = fixed[2];
        }
      }
    }
  }
  return out;
}

/**
 * Palette indices (one byte per pixel, row-major) of `image`, each pixel mapped
 * to its nearest colour (palette.nearestIndex on the full 8-bit value; the
 * same indices as `stucki(image, 0)`).
 *
 * @throws RangeError when `data` does not match the size.
 */
export function mapNearest(image: RgbaImage): Uint8Array {
  const pixels = checkImage(image);
  const { data } = image;
  const out = new Uint8Array(pixels);
  // Photos repeat colours a lot; remember the answer per 24-bit colour.
  const cache = new Map<number, number>();
  for (let i = 0, o = 0; i < pixels; i++, o += 4) {
    const key = (data[o] << 16) | (data[o + 1] << 8) | data[o + 2];
    let index = cache.get(key);
    if (index === undefined) {
      index = nearestIndex(data[o], data[o + 1], data[o + 2]);
      cache.set(key, index);
    }
    out[i] = index;
  }
  return out;
}

/**
 * Palette indices of `image` with the given options: `natural`, `stucki` or
 * `mapNearest`.
 *
 * @throws RangeError when `strength` is outside 0-1 or `data` does not match the size.
 */
export function toIndices(image: RgbaImage, options: DitherOptions = {}): Uint8Array {
  const { dither = true, strength = 1, colours = 'natural' } = options;
  checkStrength(strength);
  if (!dither) return mapNearest(image);
  return colours === 'classic' ? stucki(image, strength) : natural(image, strength);
}
