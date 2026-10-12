/**
 * The panel's seven colours. A colour's index is the 4-bit value stored in a
 * frame, so the order is fixed by the device.
 */

export type ColourName = 'black' | 'white' | 'green' | 'blue' | 'red' | 'yellow' | 'orange';

/** An sRGB triple, each channel 0-255. */
export type Rgb = readonly [r: number, g: number, b: number];

export interface PaletteColour {
  /** Value stored in a frame nibble (0-6). */
  readonly index: number;
  readonly name: ColourName;
  /** The RGB value used to map pictures onto this colour and to draw previews. */
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

/** Palette colours by name. */
export const COLOURS: Readonly<Record<ColourName, PaletteColour>> = Object.freeze(
  Object.fromEntries(PALETTE.map((c) => [c.name, c])) as Record<ColourName, PaletteColour>,
);

// Channels of the palette by index, for the per-pixel loops.
const PALETTE_R = Int32Array.from(PALETTE, (c) => c.rgb[0]);
const PALETTE_G = Int32Array.from(PALETTE, (c) => c.rgb[1]);
const PALETTE_B = Int32Array.from(PALETTE, (c) => c.rgb[2]);

const BLACK: Rgb = COLOURS.black.rgb;

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
 * RGB of a frame nibble for previews. Values without a palette colour (7-15)
 * render black.
 *
 * @throws RangeError when `nibble` is not an integer 0-15.
 */
export function nibbleRgb(nibble: number): Rgb {
  if (!Number.isInteger(nibble) || nibble < 0 || nibble > 15) {
    throw new RangeError(`a nibble is an integer 0-15, got ${nibble}`);
  }
  return PALETTE[nibble]?.rgb ?? BLACK;
}
