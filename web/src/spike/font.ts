/**
 * A tiny 5 x 8 bitmap font for the diagnostics test card, so the card is
 * drawn without a canvas: the same pixels in every browser and in tests.
 *
 * Each glyph is 5 columns by 8 rows: rows 0-6 hold capitals and digits, row
 * 7 the descenders of g, j, p, q and y. Characters advance by 6 columns (one
 * blank column between glyphs). Characters without a glyph draw as a box.
 */

/** Glyph width in font pixels. */
export const GLYPH_WIDTH = 5;
/** Glyph height in font pixels, descender row included. */
export const GLYPH_HEIGHT = 8;
/** Horizontal distance from one character to the next, in font pixels. */
export const ADVANCE = GLYPH_WIDTH + 1;

/** Rows of `#` (ink) and `.` (paper), top to bottom, separated by spaces. Seven rows get a blank eighth. */
const SOURCE: Readonly<Record<string, string>> = {
  ' ': '..... ..... ..... ..... ..... ..... .....',
  '0': '.###. #...# #..## #.#.# ##..# #...# .###.',
  '1': '..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.',
  '2': '.###. #...# ....# ...#. ..#.. .#... #####',
  '3': '##### ...#. ..#.. ...#. ....# #...# .###.',
  '4': '...#. ..##. .#.#. #..#. ##### ...#. ...#.',
  '5': '##### #.... ####. ....# ....# #...# .###.',
  '6': '..##. .#... #.... ####. #...# #...# .###.',
  '7': '##### ....# ...#. ..#.. .#... .#... .#...',
  '8': '.###. #...# #...# .###. #...# #...# .###.',
  '9': '.###. #...# #...# .#### ....# ...#. .##..',
  A: '.###. #...# #...# ##### #...# #...# #...#',
  B: '####. #...# #...# ####. #...# #...# ####.',
  C: '.###. #...# #.... #.... #.... #...# .###.',
  D: '###.. #..#. #...# #...# #...# #..#. ###..',
  E: '##### #.... #.... ####. #.... #.... #####',
  F: '##### #.... #.... ####. #.... #.... #....',
  G: '.###. #...# #.... #.### #...# #...# .####',
  H: '#...# #...# #...# ##### #...# #...# #...#',
  I: '.###. ..#.. ..#.. ..#.. ..#.. ..#.. .###.',
  J: '..### ...#. ...#. ...#. ...#. #..#. .##..',
  K: '#...# #..#. #.#.. ##... #.#.. #..#. #...#',
  L: '#.... #.... #.... #.... #.... #.... #####',
  M: '#...# ##.## #.#.# #.#.# #...# #...# #...#',
  N: '#...# #...# ##..# #.#.# #..## #...# #...#',
  O: '.###. #...# #...# #...# #...# #...# .###.',
  P: '####. #...# #...# ####. #.... #.... #....',
  Q: '.###. #...# #...# #...# #.#.# #..#. .##.#',
  R: '####. #...# #...# ####. #.#.. #..#. #...#',
  S: '.#### #.... #.... .###. ....# ....# ####.',
  T: '##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..',
  U: '#...# #...# #...# #...# #...# #...# .###.',
  V: '#...# #...# #...# #...# #...# .#.#. ..#..',
  W: '#...# #...# #...# #.#.# #.#.# #.#.# .#.#.',
  X: '#...# #...# .#.#. ..#.. .#.#. #...# #...#',
  Y: '#...# #...# .#.#. ..#.. ..#.. ..#.. ..#..',
  Z: '##### ....# ...#. ..#.. .#... #.... #####',
  a: '..... ..... .###. ....# .#### #...# .####',
  b: '#.... #.... #.##. ##..# #...# #...# ####.',
  c: '..... ..... .###. #.... #.... #...# .###.',
  d: '....# ....# .##.# #..## #...# #...# .####',
  e: '..... ..... .###. #...# ##### #.... .###.',
  f: '..##. .#..# .#... ###.. .#... .#... .#...',
  g: '..... ..... .#### #...# #...# .#### ....# .###.',
  h: '#.... #.... #.##. ##..# #...# #...# #...#',
  i: '..#.. ..... .##.. ..#.. ..#.. ..#.. .###.',
  j: '...#. ..... ..##. ...#. ...#. ...#. #..#. .##..',
  k: '#.... #.... #..#. #.#.. ##... #.#.. #..#.',
  l: '.##.. ..#.. ..#.. ..#.. ..#.. ..#.. .###.',
  m: '..... ..... ##.#. #.#.# #.#.# #...# #...#',
  n: '..... ..... #.##. ##..# #...# #...# #...#',
  o: '..... ..... .###. #...# #...# #...# .###.',
  p: '..... ..... ####. #...# #...# ####. #.... #....',
  q: '..... ..... .#### #...# #...# .#### ....# ....#',
  r: '..... ..... #.##. ##..# #.... #.... #....',
  s: '..... ..... .#### #.... .###. ....# ####.',
  t: '.#... .#... ###.. .#... .#... .#..# ..##.',
  u: '..... ..... #...# #...# #...# #..## .##.#',
  v: '..... ..... #...# #...# #...# .#.#. ..#..',
  w: '..... ..... #...# #...# #.#.# #.#.# .#.#.',
  x: '..... ..... #...# .#.#. ..#.. .#.#. #...#',
  y: '..... ..... #...# #...# #...# .#### ....# .###.',
  z: '..... ..... ##### ...#. ..#.. .#... #####',
  '-': '..... ..... ..... ##### ..... ..... .....',
  ':': '..... .##.. .##.. ..... .##.. .##.. .....',
  '.': '..... ..... ..... ..... ..... .##.. .##..',
  ',': '..... ..... ..... ..... .##.. .##.. ..#.. .#...',
  '/': '..... ....# ...#. ..#.. .#... #.... .....',
  '#': '.#.#. .#.#. ##### .#.#. ##### .#.#. .#.#.',
  '(': '...#. ..#.. .#... .#... .#... ..#.. ...#.',
  ')': '.#... ..#.. ...#. ...#. ...#. ..#.. .#...',
  '%': '##... ##..# ...#. ..#.. .#... #..## ...##',
  '+': '..... ..#.. ..#.. ##### ..#.. ..#.. .....',
  '?': '.###. #...# ....# ...#. ..#.. ..... ..#..',
};

/** The characters the font can draw. */
export const FONT_CHARACTERS: readonly string[] = Object.freeze(Object.keys(SOURCE));

const cache = new Map<string, Uint8Array>();

function parse(character: string, source: string): Uint8Array {
  const rows = source.split(' ');
  if (rows.length < GLYPH_HEIGHT - 1 || rows.length > GLYPH_HEIGHT) {
    throw new Error(`glyph ${JSON.stringify(character)} has ${rows.length} rows`);
  }
  const bits = new Uint8Array(GLYPH_WIDTH * GLYPH_HEIGHT);
  rows.forEach((row, y) => {
    if (!/^[#.]{5}$/.test(row)) throw new Error(`glyph ${JSON.stringify(character)}: bad row ${JSON.stringify(row)}`);
    for (let x = 0; x < GLYPH_WIDTH; x++) bits[y * GLYPH_WIDTH + x] = row[x] === '#' ? 1 : 0;
  });
  return bits;
}

/**
 * The glyph of `character` as GLYPH_WIDTH x GLYPH_HEIGHT bits, row-major (1 =
 * ink); the box glyph when the font lacks it.
 */
export function glyph(character: string): Uint8Array {
  if (!hasGlyph(character)) return MISSING;
  let bits = cache.get(character);
  if (!bits) {
    bits = parse(character, SOURCE[character] as string);
    cache.set(character, bits);
  }
  return bits;
}

/** Drawn for characters the font lacks: a box. */
const MISSING = parse('missing', '##### #...# #...# #...# #...# #...# #####');

/** Whether the font has a glyph for `character`. */
export function hasGlyph(character: string): boolean {
  return Object.prototype.hasOwnProperty.call(SOURCE, character);
}

/** A grid of palette indices, row-major (`width * height` entries). */
export interface IndexCanvas {
  readonly width: number;
  readonly height: number;
  readonly pixels: Uint8Array;
}

/** Width in pixels of `text` drawn at `scale` (no trailing gap). */
export function measureText(text: string, scale: number): number {
  const length = [...text].length;
  return length === 0 ? 0 : (length * ADVANCE - 1) * scale;
}

/**
 * Draw `text` with its top-left corner at (x, y), each font pixel a
 * `scale` x `scale` square of palette index `index`. Pixels outside the
 * canvas are skipped.
 */
export function drawText(
  canvas: IndexCanvas,
  text: string,
  x: number,
  y: number,
  scale: number,
  index: number,
): void {
  let left = x;
  for (const character of text) {
    const bits = glyph(character);
    for (let row = 0; row < GLYPH_HEIGHT; row++) {
      for (let column = 0; column < GLYPH_WIDTH; column++) {
        if (bits[row * GLYPH_WIDTH + column]) {
          fillRect(canvas, left + column * scale, y + row * scale, scale, scale, index);
        }
      }
    }
    left += ADVANCE * scale;
  }
}

/** Fill a rectangle with palette index `index`, clipped to the canvas. */
export function fillRect(
  canvas: IndexCanvas,
  x: number,
  y: number,
  width: number,
  height: number,
  index: number,
): void {
  const x0 = Math.max(0, Math.floor(x));
  const y0 = Math.max(0, Math.floor(y));
  const x1 = Math.min(canvas.width, Math.floor(x + width));
  const y1 = Math.min(canvas.height, Math.floor(y + height));
  for (let row = y0; row < y1; row++) canvas.pixels.fill(index, row * canvas.width + x0, row * canvas.width + x1);
}

/** Outline a rectangle with a border `thickness` pixels wide, drawn inside it. */
export function strokeRect(
  canvas: IndexCanvas,
  x: number,
  y: number,
  width: number,
  height: number,
  thickness: number,
  index: number,
): void {
  fillRect(canvas, x, y, width, thickness, index);
  fillRect(canvas, x, y + height - thickness, width, thickness, index);
  fillRect(canvas, x, y, thickness, height, index);
  fillRect(canvas, x + width - thickness, y, thickness, height, index);
}
