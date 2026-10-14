/**
 * The panel's seven colours. A colour's index is the 4-bit value stored in a
 * frame, so the order is fixed by the device.
 *
 * Each colour has two RGB values: the ideal one (PALETTE), which Classic
 * dithering, plain nearest colour and the drawing of calendar pages and cards
 * map onto, and the one the panel really shows (PANEL_RGB), in which every
 * preview is drawn (shared/DITHER.md §7).
 */

import tables from '../../../shared/dither/natural-tables.json';

export type ColourName = 'black' | 'white' | 'green' | 'blue' | 'red' | 'yellow' | 'orange';

/** An sRGB triple, each channel 0-255. */
export type Rgb = readonly [r: number, g: number, b: number];

export interface PaletteColour {
  /** Value stored in a frame nibble (0-6). */
  readonly index: number;
  readonly name: ColourName;
  /** The ideal RGB value, which Classic dithering and nearest colour map pictures onto. Previews use PANEL_RGB. */
  readonly rgb: Rgb;
}

function colour(index: number, name: ColourName, rgb: Rgb): PaletteColour {
  return Object.freeze({ index, name, rgb: Object.freeze(rgb) });
}

/** The palette, ordered by index. */
export const PALETTE: readonly PaletteColour[] = Object.freeze([
  colour(0, 'black', [0, 0, 0]),
  colour(1, 'white', [255, 255, 255]),
  colour(2, 'green', [0, 255, 0]),
  colour(3, 'blue', [0, 0, 255]),
  colour(4, 'red', [255, 0, 0]),
  colour(5, 'yellow', [255, 255, 0]),
  colour(6, 'orange', [255, 125, 0]),
]);

/**
 * The colours the panel really shows, by index, in sRGB relative to its white:
 * `palette_srgb` of shared/dither/natural-tables.json (from the datasheet), the
 * table Natural dithering is made from. Previews draw frames in these.
 */
export const PANEL_RGB: readonly Rgb[] = Object.freeze(
  tables.palette_srgb.map(([r, g, b]) => Object.freeze([r, g, b] as const) as Rgb),
);

/** Palette colours by name. */
export const COLOURS: Readonly<Record<ColourName, PaletteColour>> = Object.freeze(
  Object.fromEntries(PALETTE.map((c) => [c.name, c])) as Record<ColourName, PaletteColour>,
);

// Channels of the palette by index, for the per-pixel loops.
const PALETTE_R = Int32Array.from(PALETTE, (c) => c.rgb[0]);
const PALETTE_G = Int32Array.from(PALETTE, (c) => c.rgb[1]);
const PALETTE_B = Int32Array.from(PALETTE, (c) => c.rgb[2]);

const PANEL_BLACK: Rgb = PANEL_RGB[COLOURS.black.index];

/**
 * Index of the palette colour closest to (r, g, b): the smallest squared RGB
 * distance, and the lowest index on a tie. Channels may lie outside 0-255
 * (error diffusion produces such values); they are used as given.
 */
export function nearestIndex(r: number, g: number, b: number): number {
  let best = 0;
  let bestDistance = Infinity;
  for (let k = 0; k < PALETTE_R.length; k++) {
    const dr = PALETTE_R[k] - r;
    const dg = PALETTE_G[k] - g;
    const db = PALETTE_B[k] - b;
    const distance = dr * dr + dg * dg + db * db;
    // Strictly smaller: on a tie the earlier (lower) index stays.
    if (distance < bestDistance) {
      best = k;
      bestDistance = distance;
    }
  }
  return best;
}

/**
 * RGB of a frame nibble for previews: its panel colour (PANEL_RGB). Values
 * without a palette colour (7-15) render as the panel's black.
 *
 * @throws RangeError when `nibble` is not an integer 0-15.
 */
export function nibbleRgb(nibble: number): Rgb {
  if (!Number.isInteger(nibble) || nibble < 0 || nibble > 15) {
    throw new RangeError(`a nibble is an integer 0-15, got ${nibble}`);
  }
  return PANEL_RGB[nibble] ?? PANEL_BLACK;
}
