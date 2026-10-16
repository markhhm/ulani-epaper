/**
 * Previews of frames as the panel shows them (shared/DITHER.md §7): drawn in the panel's own colours
 * (palette.PANEL_RGB), never the ideal ones, for Natural, Bright and Classic frames, calendar pages and cards
 * alike. A preview smaller than the frame averages the frame's pixels in linear light, as the eye does
 * on the panel; averaging sRGB numbers or skipping pixels would make the grain look worse than it is.
 * At the frame's size or larger each dot stays one ink (nearest neighbour).
 */

import tables from '../../../shared/dither/natural-tables.json';
import type { RgbaImage } from './frame';
import { PANEL_RGB } from './palette';

/** Palette indices, one per pixel, row-major. */
export interface IndexImage {
  readonly width: number;
  readonly height: number;
  readonly indices: Uint8Array;
}

// Every index value to its panel colour (values without one, 7-255, to black): as an opaque RGBA word
// (in the platform's byte order, like the pixel words written with it) and in linear light (`pal_lin`,
// the panel colours decoded).
const PIXEL = new Uint32Array(256);
const LINEAR = new Float64Array(256 * 3);
{
  const rgba = new Uint8Array(4);
  const word = new Uint32Array(rgba.buffer);
  for (let v = 0; v < 256; v++) {
    const i = v < PANEL_RGB.length ? v : 0;
    rgba.set([...PANEL_RGB[i], 255]);
    PIXEL[v] = word[0];
    LINEAR.set(tables.pal_lin[i].map(Number), 3 * v);
  }
}

// Linear light (0-1) to an sRGB byte, in ENCODE_STEPS steps: within a small fraction of a level for the
// panel colours and their averages, which never come near black.
const ENCODE_STEPS = 4096;
const ENCODE = new Uint8Array(ENCODE_STEPS + 1);
for (let k = 0; k <= ENCODE_STEPS; k++) {
  const v = k / ENCODE_STEPS;
  ENCODE[k] = Math.round(255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055));
}
const encode = (v: number): number => ENCODE[Math.min(ENCODE_STEPS, Math.round(v * ENCODE_STEPS))];

/**
 * Box filter weights from `from` cells to `to` cells: output cell i covers source cells
 * [i * from / to, (i + 1) * from / to); `share[i * span + k]` is the part of it that source cell
 * `first[i] + k` makes up (0 where it covers none).
 */
function coverage(from: number, to: number): { first: Int32Array; span: number; share: Float64Array } {
  const scale = from / to;
  const span = Math.ceil(scale) + 1;
  const first = new Int32Array(to);
  const share = new Float64Array(to * span);
  for (let i = 0; i < to; i++) {
    const start = i * scale;
    const end = (i + 1) * scale;
    first[i] = Math.floor(start);
    for (let k = 0; k < span && first[i] + k < from; k++) {
      const j = first[i] + k;
      const overlap = Math.min(end, j + 1) - Math.max(start, j);
      if (overlap > 0) share[i * span + k] = overlap / scale;
    }
  }
  return { first, span, share };
}

/**
 * `source` as the panel shows it, `width` x `height` pixels, opaque: averaged in linear light where it
 * shrinks, nearest neighbour when it is at least the source's size both ways.
 *
 * @throws RangeError when a size is not whole pixels or `indices` does not match the source's size.
 */
export function previewImage(source: IndexImage, width: number, height: number): RgbaImage {
  const { width: sw, height: sh, indices } = source;
  for (const n of [width, height, sw, sh]) {
    if (!Number.isInteger(n) || n < 0) throw new RangeError(`sizes are whole pixels, got ${n}`);
  }
  if (indices.length !== sw * sh) throw new RangeError(`a ${sw} x ${sh} picture has ${sw * sh} indices, got ${indices.length}`);
  const data = new Uint8ClampedArray(width * height * 4);
  if (width === 0 || height === 0 || sw === 0 || sh === 0) return { width, height, data };

  if (width >= sw && height >= sh) {
    const pixels = new Uint32Array(data.buffer);
    const columns = Int32Array.from({ length: width }, (_, x) => Math.floor((x * sw) / width));
    for (let y = 0, o = 0; y < height; y++) {
      const row = Math.floor((y * sh) / height) * sw;
      for (let x = 0; x < width; x++) pixels[o++] = PIXEL[indices[row + columns[x]]];
    }
    return { width, height, data };
  }

  // Across each row of the source first, then down.
  const across = coverage(sw, width);
  const rows = new Float32Array(width * sh * 3);
  for (let y = 0, o = 0; y < sh; y++) {
    for (let x = 0; x < width; x++, o += 3) {
      let r = 0;
      let g = 0;
      let b = 0;
      const from = y * sw + across.first[x];
      for (let k = 0; k < across.span; k++) {
        const w = across.share[x * across.span + k];
        if (w === 0) continue;
        const v = 3 * indices[from + k];
        r += LINEAR[v] * w;
        g += LINEAR[v + 1] * w;
        b += LINEAR[v + 2] * w;
      }
      rows[o] = r;
      rows[o + 1] = g;
      rows[o + 2] = b;
    }
  }
  const down = coverage(sh, height);
  const sum = new Float64Array(width * 3);
  for (let y = 0, p = 0; y < height; y++) {
    sum.fill(0);
    for (let k = 0; k < down.span; k++) {
      const w = down.share[y * down.span + k];
      if (w === 0) continue;
      const from = (down.first[y] + k) * width * 3;
      for (let o = 0; o < sum.length; o++) sum[o] += rows[from + o] * w;
    }
    for (let o = 0; o < sum.length; o += 3, p += 4) {
      data[p] = encode(sum[o]);
      data[p + 1] = encode(sum[o + 1]);
      data[p + 2] = encode(sum[o + 2]);
      data[p + 3] = 255;
    }
  }
  return { width, height, data };
}
