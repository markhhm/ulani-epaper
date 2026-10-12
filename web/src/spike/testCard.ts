/**
 * The diagnostics test card: a panel-sized picture drawn straight in palette
 * indices, so every pixel is exactly one of the seven colours and the card
 * looks the same on every device.
 *
 * Layout (800 x 480): a black frame along the panel edge; seven colour bars
 * in palette order, each labelled with its index and name; a box with the
 * page number; "Paperhue test" and the time the card was drawn. The time
 * makes every card different, so the device never answers "unchanged" to
 * a new one.
 */

import { packIndices } from '../core/frame';
import { PALETTE } from '../core/palette';
import { HEIGHT, USER_SLOTS, WIDTH } from '../core/protocol';
import { drawText, fillRect, GLYPH_HEIGHT, type IndexCanvas, measureText, strokeRect } from './font';

export const TEST_CARD_TITLE = 'Paperhue test';

const INK = PALETTE[0].index; // black
const PAPER = PALETTE[1].index; // white

export interface TestCardOptions {
  /** The page the card is meant for (1-4); printed on the card. */
  readonly page: number;
  /** Printed under the title, e.g. formatStamp(new Date()). */
  readonly stamp: string;
}

export interface Rect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** Where the card puts things; exported for tests. */
export const LAYOUT = Object.freeze({
  edge: 4,
  bars: Object.freeze({ x: 24, y: 24, width: 752, height: 208 }),
  labelY: 244,
  labelScale: 2,
  pageBox: Object.freeze({ x: 24, y: 280, width: 200, height: 176 }),
  pageLabelScale: 3,
  pageDigitScale: 16,
  textX: 252,
  titleY: 292,
  titleScale: 6,
  stampY: 368,
  stampScale: 4,
});

/** The seven colour bars, in palette order. */
export function barRects(): Rect[] {
  const { x, y, width, height } = LAYOUT.bars;
  return PALETTE.map((_, i) => {
    const left = x + Math.round((i * width) / PALETTE.length);
    const right = x + Math.round(((i + 1) * width) / PALETTE.length);
    return { x: left, y, width: right - left, height };
  });
}

/**
 * The card as palette indices, WIDTH x HEIGHT, row-major.
 *
 * @throws RangeError when `page` is not one of USER_SLOTS.
 */
export function drawTestCard(options: TestCardOptions): Uint8Array {
  const { page, stamp } = options;
  if (!USER_SLOTS.includes(page)) {
    throw new RangeError(`page must be one of ${USER_SLOTS.join(', ')}, got ${page}`);
  }
  const canvas: IndexCanvas = { width: WIDTH, height: HEIGHT, pixels: new Uint8Array(WIDTH * HEIGHT).fill(PAPER) };

  strokeRect(canvas, 0, 0, WIDTH, HEIGHT, LAYOUT.edge, INK);

  // Colour bars, outlined so the white one shows, each with "index NAME" below.
  const bars = LAYOUT.bars;
  strokeRect(canvas, bars.x - 2, bars.y - 2, bars.width + 4, bars.height + 4, 2, INK);
  barRects().forEach((bar, i) => {
    const colour = PALETTE[i];
    fillRect(canvas, bar.x, bar.y, bar.width, bar.height, colour.index);
    const label = `${colour.index} ${colour.name.toUpperCase()}`;
    const labelX = bar.x + Math.floor((bar.width - measureText(label, LAYOUT.labelScale)) / 2);
    drawText(canvas, label, labelX, LAYOUT.labelY, LAYOUT.labelScale, INK);
  });

  // Page box: "PAGE" over a large digit.
  const box = LAYOUT.pageBox;
  strokeRect(canvas, box.x, box.y, box.width, box.height, 4, INK);
  const word = 'PAGE';
  const wordScale = LAYOUT.pageLabelScale;
  drawText(canvas, word, box.x + Math.floor((box.width - measureText(word, wordScale)) / 2), box.y + 12, wordScale, INK);
  const digit = String(page);
  const digitScale = LAYOUT.pageDigitScale;
  const digitY = box.y + 12 + GLYPH_HEIGHT * wordScale;
  drawText(canvas, digit, box.x + Math.floor((box.width - measureText(digit, digitScale)) / 2), digitY, digitScale, INK);

  drawText(canvas, TEST_CARD_TITLE, LAYOUT.textX, LAYOUT.titleY, LAYOUT.titleScale, INK);
  drawText(canvas, stamp, LAYOUT.textX, LAYOUT.stampY, LAYOUT.stampScale, INK);

  return canvas.pixels;
}

/** The card as a packed frame (FRAME_BYTES), ready to upload. */
export function testCardFrame(options: TestCardOptions): Uint8Array {
  return packIndices(drawTestCard(options));
}
