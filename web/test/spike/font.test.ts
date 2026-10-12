import { describe, expect, it } from 'vitest';
import {
  ADVANCE,
  drawText,
  FONT_CHARACTERS,
  fillRect,
  GLYPH_HEIGHT,
  GLYPH_WIDTH,
  glyph,
  hasGlyph,
  type IndexCanvas,
  measureText,
  strokeRect,
} from '../../src/spike/font';

function canvas(width: number, height: number, fill = 1): IndexCanvas {
  return { width, height, pixels: new Uint8Array(width * height).fill(fill) };
}

/** The canvas as rows of `#` (index 0) and `.` (anything else). */
function picture(target: IndexCanvas): string[] {
  const rows: string[] = [];
  for (let y = 0; y < target.height; y++) {
    let row = '';
    for (let x = 0; x < target.width; x++) row += target.pixels[y * target.width + x] === 0 ? '#' : '.';
    rows.push(row);
  }
  return rows;
}

describe('glyphs', () => {
  it('cover digits, both cases of the alphabet and the punctuation the card uses', () => {
    const wanted = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz -:./';
    for (const character of wanted) expect(hasGlyph(character), character).toBe(true);
  });

  it('are all well formed: 5 x 8 bits of 0 and 1', () => {
    for (const character of FONT_CHARACTERS) {
      const bits = glyph(character);
      expect(bits.length, character).toBe(GLYPH_WIDTH * GLYPH_HEIGHT);
      expect(bits.every((bit) => bit === 0 || bit === 1), character).toBe(true);
    }
  });

  it('keep capitals and digits above the descender row; g j p q y use it', () => {
    const lastRow = (character: string) => glyph(character).subarray((GLYPH_HEIGHT - 1) * GLYPH_WIDTH);
    for (const character of 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') {
      expect([...lastRow(character)].every((bit) => bit === 0), character).toBe(true);
    }
    for (const character of 'gjpqy') expect([...lastRow(character)].some((bit) => bit === 1), character).toBe(true);
  });

  it('give every visible character some ink and the space none', () => {
    for (const character of FONT_CHARACTERS) {
      const ink = glyph(character).reduce((sum, bit) => sum + bit, 0);
      if (character === ' ') expect(ink).toBe(0);
      else expect(ink, character).toBeGreaterThan(0);
    }
  });

  it('draw a box for characters the font lacks', () => {
    expect(hasGlyph('紙')).toBe(false);
    const box = glyph('紙');
    expect([...box.subarray(0, GLYPH_WIDTH)]).toEqual([1, 1, 1, 1, 1]);
    expect(glyph('é')).toEqual(box);
  });
});

describe('measureText', () => {
  it('counts 6 font pixels per character minus the trailing gap, times the scale', () => {
    expect(ADVANCE).toBe(6);
    expect(measureText('', 3)).toBe(0);
    expect(measureText('A', 1)).toBe(5);
    expect(measureText('AB', 2)).toBe(22);
    expect(measureText('Paperhue test', 6)).toBe(462);
  });
});

describe('drawText', () => {
  it('draws the glyph pattern at scale 1', () => {
    const target = canvas(5, 8);
    drawText(target, 'T', 0, 0, 1, 0);
    expect(picture(target)).toEqual(['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..', '.....']);
  });

  it('scales each font pixel to a square and advances by 6 columns', () => {
    const target = canvas(22, 16);
    drawText(target, 'll', 0, 0, 2, 0);
    const rows = picture(target);
    // "l" starts with ".##.." on its first row; scaled by 2 and repeated 12 pixels later.
    expect(rows[0]).toBe('..####........####....');
    expect(rows[1]).toBe(rows[0]);
  });

  it('clips at the canvas edges', () => {
    const target = canvas(4, 4);
    expect(() => drawText(target, 'W', -2, -3, 1, 0)).not.toThrow();
    expect(() => drawText(target, 'W', 3, 3, 5, 0)).not.toThrow();
  });
});

describe('fillRect and strokeRect', () => {
  it('fill within the canvas only', () => {
    const target = canvas(4, 3);
    fillRect(target, -1, 1, 3, 5, 0);
    expect(picture(target)).toEqual(['....', '##..', '##..']);
  });

  it('outline inside the rectangle', () => {
    const target = canvas(5, 4);
    strokeRect(target, 0, 0, 5, 4, 1, 0);
    expect(picture(target)).toEqual(['#####', '#...#', '#...#', '#####']);
  });
});
