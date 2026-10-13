import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { clean, readFont } from '../src/core/otf';
import { bundledFonts, fontBytes } from './calendarFace';

const { regular, bold } = bundledFonts();

describe('the bundled fonts', () => {
  it('are the same files as the Python app bundles', () => {
    for (const isBold of [false, true]) {
      const name = `NotoSansCJKtc-${isBold ? 'Bold' : 'Regular'}-subset.otf`;
      const python = new URL(`../../python/src/ulani_epaper/fonts/${name}`, import.meta.url);
      expect(Buffer.compare(fontBytes(isBold), readFileSync(python))).toBe(0);
    }
  });

  it('say which characters have a glyph', () => {
    expect(regular.has('國'.codePointAt(0) as number)).toBe(true);
    expect(regular.has(0x41)).toBe(true);
    expect(regular.has(0x1f382)).toBe(false); // 🎂: no emoji
    expect(bold.has(0x1f382)).toBe(false);
  });

  it('give the advance widths of Python (Pillow basic layout: whole pixels, halves up)', () => {
    // recorded from ulani_epaper.fonts.load(size, bold).getlength(char)
    const at = (font: typeof regular, ch: string, size: number) => font.advance(ch.codePointAt(0) as number, size);
    expect([at(regular, '0', 20), at(regular, 'M', 20), at(regular, '國', 20), at(regular, ':', 20)]).toEqual([11, 16, 20, 6]);
    expect([at(bold, '0', 20), at(bold, 'M', 20), at(bold, '.', 18)]).toEqual([12, 17, 6]);
    expect(at(regular, 'f', 20)).toBe(7); // 6.5 px
    expect(at(bold, "'", 20)).toBe(7); // 6.5 px
    expect(at(regular, 'Y', 16)).toBe(9); // 8.496 px: FreeType rounds in 1/64 px first
  });

  it('refuse a file that is not a font', () => {
    expect(() => readFont(new Uint8Array(100))).toThrow();
  });
});

describe('clean', () => {
  const has = regular.has.bind(regular);

  it('drops emoji, joiners and variation selectors, and folds white space', () => {
    expect(clean('🎂🎉', has)).toBe('');
    expect(clean('a‍b️', has)).toBe('ab');
    expect(clean('  開會 \n 3F\t大會議室  ', has)).toBe('開會 3F 大會議室');
    expect(clean('　全形 空白', has)).toBe('全形 空白');
  });

  it('composes text (NFC)', () => {
    expect(clean('Café', has)).toBe('Café');
  });
});
