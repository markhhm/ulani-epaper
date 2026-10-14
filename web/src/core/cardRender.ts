/**
 * Drawing a card into palette indices (shared/CARDS.md, "Drawing"): the background, then every line
 * the layout places, each outlined at the offsets of the reference and filled on top, in pure panel
 * colours with no anti-aliasing. The glyph shapes come from a `TextRasterizer` (a canvas in the
 * browser, a stand-in in tests); everything else is here.
 */

import { type Card } from './cards';
import { layoutCard, type Measure, outlineOffsets, type PlacedLine } from './cardLayout';
import { COLOURS } from './palette';
import { crc32, HEIGHT, WIDTH } from './protocol';
import type { Dithering } from './settings';

/** A line of text as ink: `ink[y * width + x]` is 1 where the glyphs are, no partial coverage. */
export interface Mask {
  readonly width: number;
  readonly height: number;
  /** Column of the text's origin (its left edge on the baseline) inside the mask. */
  readonly originX: number;
  /** Row of the baseline inside the mask. */
  readonly baseline: number;
  readonly ink: Uint8Array;
}

/** The bold font: measuring (as for the layout) and drawing a line as ink. */
export interface TextRasterizer extends Measure {
  mask(text: string, size: number): Mask;
}

export function stamp(indices: Uint8Array, mask: Mask, left: number, baseline: number, index: number): void {
  const x0 = left - mask.originX;
  const y0 = baseline - mask.baseline;
  for (let my = 0; my < mask.height; my++) {
    const y = y0 + my;
    if (y < 0 || y >= HEIGHT) continue;
    for (let mx = 0; mx < mask.width; mx++) {
      const x = x0 + mx;
      if (x >= 0 && x < WIDTH && mask.ink[my * mask.width + mx]) indices[y * WIDTH + x] = index;
    }
  }
}

function drawLine(indices: Uint8Array, line: PlacedLine, raster: TextRasterizer): void {
  const mask = raster.mask(line.text, line.size);
  const width = raster.width(line.text, line.size);
  const left = line.anchor === 'left' ? line.x : line.anchor === 'right' ? line.x - width : Math.floor(line.x - width / 2 + 0.5);
  if (line.outline > 0) {
    const index = COLOURS[line.outlineColor].index;
    for (const [dx, dy] of outlineOffsets(line.outline)) stamp(indices, mask, left + dx, line.y + dy, index);
  }
  stamp(indices, mask, left, line.y, COLOURS[line.color].index);
}

/**
 * The card as 800 x 480 palette indices. `background` is the photo already cropped, resized and dithered
 * to the screen (indices), or null for the plain colour of the card; it is copied, never changed.
 */
export function renderCardIndices(card: Card, background: Uint8Array | null, raster: TextRasterizer): Uint8Array {
  const indices = new Uint8Array(WIDTH * HEIGHT);
  if (background) indices.set(background);
  else indices.fill(COLOURS['color' in card.background ? card.background.color : 'white'].index);
  for (const line of layoutCard(card, raster)) drawLine(indices, line, raster);
  return indices;
}

/** A fingerprint of everything that decides how `card` is drawn with `dithering` (not its id). */
export function cardSig(card: Card, dithering: Dithering): string {
  const text = `${dithering.colours}|${dithering.grain}|${JSON.stringify(card.background)}|${JSON.stringify(card.texts)}`;
  return crc32(new TextEncoder().encode(text)).toString(16).padStart(8, '0');
}
