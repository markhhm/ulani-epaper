/**
 * 自然 / Natural colours (shared/DITHER.md §2-§5): each colour is first mapped to what the panel can
 * really show, in linear light (step A), then serpentine Stucki error diffusion matches it against the
 * panel's own colours, letting each pixel use only black, white and the two inks either side of its hue
 * (step B).
 *
 * Python, TypeScript and Swift give the same bytes for it (shared/vectors/natural-vectors.json), so
 * the arithmetic follows DITHER.md §2 to the letter: doubles only, every expression evaluated in the
 * order it is written there (do not reorder, factor or "simplify" any of them), no Math functions and
 * no rounding. Every value that needs a power or a root is shipped in
 * shared/dither/natural-tables.json, read here as decimal strings.
 */

import tables from '../../../shared/dither/natural-tables.json';
import type { RgbaImage } from './frame';

/**
 * The version of shared/vectors/natural-vectors.json this module matches. It is part of a card's
 * fingerprint, so frames drawn by an older Natural are drawn again.
 */
export const NATURAL_VERSION = 2;

const doubles = (values: readonly string[]): Float64Array => Float64Array.from(values, Number);

/** DEC: input byte -> linear light, with the contrast curve folded in. */
const DEC = doubles(tables.decode);
/** PAL: the panel colours in linear light, three channels per index. */
const PAL = doubles(tables.pal_lin.flat());
const [L0, L1, L2] = doubles(tables.luma);
const [K0, K1, K2] = doubles(tables.k);
const [WK0, WK1, WK2] = doubles(tables.wk);
const YK = Number(tables.yk);
const YR = Number(tables.yrange);
/** The convex hull of PAL: nx, ny, nz, d per facet, in the shipped order. */
const FACETS = doubles(tables.facets.flat());
const [E10, E11, E12] = doubles(tables.e1);
const [E20, E21, E22] = doubles(tables.e2);
/** The two inks of each hue sector. */
const SECTORS = Uint8Array.from(tables.sectors.flat());
/** ax, ay, bx, by per sector: the E1/E2 coordinates of its two inks. */
const SXY = doubles(tables.sector_xy.flat());
const SECTOR_COUNT = tables.sectors.length;
const SAT = Number(tables.sat);
const DEAD = Number(tables.dead);
const KNEE = Number(tables.knee);
const ALPHA = Number(tables.alpha);
/** INK_U: each panel colour's place on the grey scale, K 0 and W 1. */
const INK_U = doubles(tables.ink_u);
const CUSP = Number(tables.cusp);
const SPAN = Number(tables.cusp_span);
const CREF = Number(tables.cusp_ref);

/**
 * Step A (DITHER.md §4) for the colour (r8, g8, b8): writes its target in linear light to
 * `target[at..at + 2]` and returns its candidate set, -1 for near-grey (black and white only) or the
 * sector 0-4 (black, white and the sector's two inks). A colour the panel cannot show at its own
 * lightness is aimed from a darker (or lighter) grey, towards the lightness where its hue is most
 * colourful (the cusp move), so a light blue sky stays blue instead of turning grey-white.
 */
function stepA(r8: number, g8: number, b8: number, target: Float64Array, at: number): number {
  let r = DEC[r8];
  let g = DEC[g8];
  let b = DEC[b8];
  let y = L0 * r + L1 * g + L2 * b;
  r = y + SAT * (r - y);
  g = y + SAT * (g - y);
  b = y + SAT * (b - y);
  r = K0 + WK0 * r;
  g = K1 + WK1 * g;
  b = K2 + WK2 * b;
  let u = (L0 * r + L1 * g + L2 * b - YK) / YR;
  u = u < 0 ? 0 : u > 1 ? 1 : u;
  let g0 = K0 + WK0 * u;
  let g1 = K1 + WK1 * u;
  let g2 = K2 + WK2 * u;
  let d0 = r - g0;
  let d1 = g - g1;
  let d2 = b - g2;
  let s = Infinity;
  for (let f = 0; f < FACETS.length; f += 4) {
    const nx = FACETS[f];
    const ny = FACETS[f + 1];
    const nz = FACETS[f + 2];
    const nd = nx * d0 + ny * d1 + nz * d2;
    if (nd > 1e-12) {
      const v = (FACETS[f + 3] - (nx * g0 + ny * g1 + nz * g2)) / nd;
      if (v < s) s = v;
    }
  }
  let ratio = s === Infinity ? 0 : s <= 0 ? Infinity : 1 / s; // 1 = on the hull boundary
  if (ratio <= DEAD || ratio === Infinity) {
    target[at] = g0;
    target[at + 1] = g1;
    target[at + 2] = g2;
    return -1;
  }
  let x = E10 * d0 + E11 * d1 + E12 * d2;
  y = E20 * d0 + E21 * d1 + E22 * d2;
  let set = 0;
  let found = false;
  for (let k = 0; k < SECTOR_COUNT; k++) {
    const o = 4 * k;
    if (SXY[o] * y - SXY[o + 1] * x >= 0 && x * SXY[o + 3] - y * SXY[o + 2] > 0) {
      set = k;
      found = true;
      break;
    }
  }
  if (ratio > 1 && found) {
    // The cusp move.
    const ax = SXY[4 * set];
    const ay = SXY[4 * set + 1];
    const bx = SXY[4 * set + 2];
    const by = SXY[4 * set + 3];
    const i = SECTORS[2 * set];
    const j = SECTORS[2 * set + 1];
    const p = ax * y - ay * x; // >= 0
    const q = x * by - y * bx; // > 0
    const t = p / (p + q); // where the hue meets the ink edge: 0 at ink i, 1 at ink j
    const uc = INK_U[i] + t * (INK_U[j] - INK_U[i]); // the lightness where this hue is most colourful
    const cx = ax + t * (bx - ax);
    const cy = ay + t * (by - ay); // that colour's place across the grey axis
    let c = (x * cx + y * cy) / (cx * cx + cy * cy) / CREF; // how colourful the pixel is, against it
    if (c > 1) c = 1;
    let e = (ratio - 1) / SPAN; // how far outside the hull, 0 on the boundary
    if (e > 1) e = 1;
    const w = CUSP * c * c * e;
    const ua = u + w * (uc - u);
    const h0 = K0 + WK0 * ua; // the anchor: a darker (or lighter) panel grey
    const h1 = K1 + WK1 * ua;
    const h2 = K2 + WK2 * ua;
    const m0 = r - h0;
    const m1 = g - h1;
    const m2 = b - h2;
    s = Infinity;
    for (let f = 0; f < FACETS.length; f += 4) {
      const nx = FACETS[f];
      const ny = FACETS[f + 1];
      const nz = FACETS[f + 2];
      const nd = nx * m0 + ny * m1 + nz * m2;
      if (nd > 1e-12) {
        const v = (FACETS[f + 3] - (nx * h0 + ny * h1 + nz * h2)) / nd;
        if (v < s) s = v;
      }
    }
    if (s > 0 && s !== Infinity) {
      // Else keep g, d and ratio as they are.
      g0 = h0;
      g1 = h1;
      g2 = h2;
      d0 = m0;
      d1 = m1;
      d2 = m2;
      ratio = 1 / s;
    }
  }
  let r1 = (ratio - DEAD) / (1 - DEAD);
  if (r1 > KNEE) {
    // Soft knee into the hull.
    x = (r1 - KNEE) / (1 - KNEE);
    r1 = KNEE + ((1 - KNEE) * x) / (1 + x);
  }
  const f = r1 / ratio;
  target[at] = g0 + f * d0;
  target[at + 1] = g1 + f * d1;
  target[at + 2] = g2 + f * d2;
  return set;
}

/**
 * Step A of one colour, for the vectors: its target in linear light and its candidate set (-1 for
 * near-grey, else the sector 0-4).
 */
export function naturalTarget(r8: number, g8: number, b8: number): { target: [number, number, number]; set: number } {
  const target = new Float64Array(3);
  const set = stepA(r8, g8, b8, target, 0);
  return { target: [target[0], target[1], target[2]], set };
}

/**
 * Palette indices (one byte per pixel, row-major) of `image`, any size, with Natural colours as
 * described at the top of this module. Alpha is ignored, as in dither.stucki.
 *
 * @param strength share of the error to diffuse, 0-1 (default 1): the grain.
 * @throws RangeError when `strength` is outside 0-1 or `data` does not match the size.
 */
export function natural(image: RgbaImage, strength = 1): Uint8Array {
  const { width, height, data } = image;
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 0 || height < 0) {
    throw new RangeError(`image size must be whole pixels, got ${width} x ${height}`);
  }
  const pixels = width * height;
  if (data.length !== pixels * 4) {
    throw new RangeError(`a ${width} x ${height} RGBA image has ${pixels * 4} bytes, got ${data.length}`);
  }
  if (!(strength >= 0 && strength <= 1)) throw new RangeError(`strength must be 0-1, got ${strength}`);

  // Step A, once per colour: a pixel whose colour came before copies that pixel's result.
  const targets = new Float64Array(pixels * 3);
  const sets = new Int8Array(pixels);
  const first = new Map<number, number>();
  for (let i = 0, o = 0; i < pixels; i++, o += 4) {
    const key = (data[o] << 16) | (data[o + 1] << 8) | data[o + 2];
    const seen = first.get(key);
    if (seen === undefined) {
      sets[i] = stepA(data[o], data[o + 1], data[o + 2], targets, 3 * i);
      first.set(key, i);
    } else {
      targets[3 * i] = targets[3 * seen];
      targets[3 * i + 1] = targets[3 * seen + 1];
      targets[3 * i + 2] = targets[3 * seen + 2];
      sets[i] = sets[seen];
    }
  }

  // Step B (DITHER.md §5).
  const taps = tables.stucki.length;
  const factor = new Float64Array(taps);
  const dxs = new Int32Array(taps);
  const dys = new Int32Array(taps);
  tables.stucki.forEach(([w, dx, dy], k) => {
    factor[k] = (w / tables.stucki_div) * strength;
    dxs[k] = dx;
    dys[k] = dy;
  });
  // The error waiting for the current row and the next two, three channels per pixel.
  let row0 = new Float64Array(width * 3);
  let row1 = new Float64Array(width * 3);
  let row2 = new Float64Array(width * 3);
  const out = new Uint8Array(pixels);
  for (let y = 0; y < height; y++) {
    const odd = y % 2 === 1;
    const sgn = odd ? -1 : 1;
    for (let n = 0; n < width; n++) {
      const x = odd ? width - 1 - n : n;
      const i = y * width + x;
      const v0 = targets[3 * i] + row0[3 * x];
      const v1 = targets[3 * i + 1] + row0[3 * x + 1];
      const v2 = targets[3 * i + 2] + row0[3 * x + 2];
      // Candidates: black, white, then the two inks of the sector.
      const set = sets[i];
      const count = set < 0 ? 2 : 4;
      let best = 0;
      let bd = Infinity;
      for (let c = 0; c < count; c++) {
        const p = c < 2 ? c : SECTORS[2 * set + c - 2];
        const q0 = PAL[3 * p] - v0;
        const q1 = PAL[3 * p + 1] - v1;
        const q2 = PAL[3 * p + 2] - v2;
        const dy = L0 * q0 + L1 * q1 + L2 * q2;
        const dist = ALPHA * dy * dy + (q0 - dy) * (q0 - dy) + (q1 - dy) * (q1 - dy) + (q2 - dy) * (q2 - dy);
        if (dist < bd) {
          best = p;
          bd = dist;
        }
      }
      out[i] = best;
      const e0 = v0 - PAL[3 * best];
      const e1 = v1 - PAL[3 * best + 1];
      const e2 = v2 - PAL[3 * best + 2];
      for (let k = 0; k < taps; k++) {
        const xx = x + dxs[k] * sgn;
        const ddy = dys[k];
        if (xx < 0 || xx >= width || y + ddy >= height) continue;
        const row = ddy === 0 ? row0 : ddy === 1 ? row1 : row2;
        const f = factor[k];
        row[3 * xx] += e0 * f;
        row[3 * xx + 1] += e1 * f;
        row[3 * xx + 2] += e2 * f;
      }
    }
    const done = row0;
    row0 = row1;
    row1 = row2;
    row2 = done.fill(0);
  }
  return out;
}
