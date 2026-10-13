/**
 * The calendar pages' font in Node tests: the bundled fonts' real widths and character coverage (the
 * same numbers as Python's Pillow), and solid boxes for ink, so what lands where can be checked
 * without a canvas.
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { Typeface } from '../src/core/calendarDraw';
import { type FontData, metricsOf, readFont } from '../src/core/otf';

const folder = fileURLToPath(new URL('../public/fonts/', import.meta.url));

export function fontBytes(bold: boolean): Uint8Array {
  return readFileSync(`${folder}NotoSansCJKtc-${bold ? 'Bold' : 'Regular'}-subset.otf`);
}

let fonts: { regular: FontData; bold: FontData } | undefined;

export function bundledFonts(): { regular: FontData; bold: FontData } {
  fonts ??= { regular: readFont(fontBytes(false)), bold: readFont(fontBytes(true)) };
  return fonts;
}

/** Real metrics; each character is a solid box of its advance, 0.7 of the size high. */
export function testFace(): Typeface {
  const { regular, bold } = bundledFonts();
  const metrics = metricsOf(regular, bold);
  return {
    ...metrics,
    mask(text, size, isBold) {
      const pad = 4;
      const above = Math.ceil(size * 1.1);
      const width = Math.ceil(metrics.width(text, size, isBold)) + 2 * pad;
      const height = above + Math.ceil(size * 0.4);
      const ink = new Uint8Array(width * height);
      const top = above - Math.round(size * 0.7);
      for (let y = top; y < above; y++) ink.fill(1, y * width + pad, y * width + width - pad);
      return { width, height, originX: pad, baseline: above, ink };
    },
  };
}
