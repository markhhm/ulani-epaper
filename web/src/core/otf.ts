/**
 * What the calendar pages need from the bundled Noto Sans CJK TC subset fonts (OpenType, CFF):
 * which characters have a glyph (the cmap) and how wide each one is (hmtx). Reading the numbers
 * from the file instead of asking a canvas gives every app the same widths, so the same text is
 * cut and wrapped in the same places, as in Python (`fonts.py`), whatever fonts the system has.
 */

export interface FontData {
  readonly unitsPerEm: number;
  /** True when the font has a glyph for the character (not the empty .notdef). */
  has(codePoint: number): boolean;
  /**
   * The advance of the character at `size` px in whole pixels, as FreeType gives it for Pillow's
   * basic layout in the Python reference: the width scaled to 1/64 px, then rounded to a pixel
   * with halves up.
   */
  advance(codePoint: number, size: number): number;
}

function fail(what: string): never {
  throw new Error(`not a font the pages can read (${what})`);
}

/** Read the tables the pages use from the bytes of an OpenType font with a format 4 cmap. */
export function readFont(bytes: Uint8Array): FontData {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tables = new Map<string, number>();
  if (bytes.byteLength < 12) fail('too short');
  for (let i = 0, n = view.getUint16(4); i < n; i++) {
    const at = 12 + 16 * i;
    if (at + 16 > bytes.byteLength) fail('table directory');
    tables.set(String.fromCharCode(...bytes.subarray(at, at + 4)), view.getUint32(at + 8));
  }
  const table = (tag: string): number => tables.get(tag) ?? fail(`no ${tag} table`);

  const unitsPerEm = view.getUint16(table('head') + 18);
  const metrics = view.getUint16(table('hhea') + 34);
  const hmtx = table('hmtx');

  // cmap: the Unicode subtable of format 4 (the characters of the Basic Multilingual Plane)
  const cmap = table('cmap');
  let sub = -1;
  for (let i = 0, n = view.getUint16(cmap + 2); i < n; i++) {
    const platform = view.getUint16(cmap + 4 + 8 * i);
    const encoding = view.getUint16(cmap + 6 + 8 * i);
    const offset = cmap + view.getUint32(cmap + 8 + 8 * i);
    if (((platform === 3 && encoding === 1) || platform === 0) && view.getUint16(offset) === 4) {
      sub = offset;
      break;
    }
  }
  if (sub < 0) fail('no Unicode cmap of format 4');
  const segments = view.getUint16(sub + 6) / 2;
  const ends = sub + 14;
  const starts = ends + 2 * segments + 2;
  const deltas = starts + 2 * segments;
  const ranges = deltas + 2 * segments;

  function glyph(codePoint: number): number {
    if (codePoint > 0xfffe) return 0;
    let lo = 0;
    let hi = segments - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (view.getUint16(ends + 2 * mid) < codePoint) lo = mid + 1;
      else hi = mid;
    }
    if (view.getUint16(starts + 2 * lo) > codePoint) return 0;
    const delta = view.getInt16(deltas + 2 * lo);
    const range = view.getUint16(ranges + 2 * lo);
    if (range === 0) return (codePoint + delta) & 0xffff;
    const id = view.getUint16(ranges + 2 * lo + range + 2 * (codePoint - view.getUint16(starts + 2 * lo)));
    return id === 0 ? 0 : (id + delta) & 0xffff;
  }

  return {
    unitsPerEm,
    has: (codePoint) => glyph(codePoint) !== 0,
    advance(codePoint, size) {
      const units = view.getUint16(hmtx + 4 * Math.min(glyph(codePoint), metrics - 1));
      const sixtyFourths = Math.floor((units * size * 64) / unitsPerEm + 0.5);
      return Math.floor((sixtyFourths + 32) / 64);
    },
  };
}

/** The width of a string and the characters that can be drawn, from a regular and a bold font. */
export function metricsOf(regular: FontData, bold: FontData) {
  return {
    width(text: string, size: number, isBold: boolean): number {
      const font = isBold ? bold : regular;
      let sum = 0;
      for (const ch of text) sum += font.advance(ch.codePointAt(0) as number, size);
      return sum;
    },
    has: (codePoint: number): boolean => regular.has(codePoint) && bold.has(codePoint),
  };
}

/**
 * Text as the pages can draw it (`fonts.clean` in Python): composed (NFC), white space and control
 * characters turned into spaces, every character without a glyph dropped (emoji, joiners, variation
 * selectors), runs of spaces folded and the ends trimmed.
 */
export function clean(text: string, has: (codePoint: number) => boolean): string {
  let out = '';
  for (const ch of text.normalize('NFC')) {
    if (/[\p{Zs}\p{Zl}\p{Zp}\p{Cc}]/u.test(ch)) out += ' ';
    else if (!/\p{Cf}/u.test(ch) && !(ch >= '︀' && ch <= '️') && has(ch.codePointAt(0) as number)) out += ch;
  }
  return out.split(' ').filter(Boolean).join(' ');
}
