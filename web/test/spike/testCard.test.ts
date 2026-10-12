import { describe, expect, it } from 'vitest';
import { packIndices } from '../../src/core/frame';
import { PALETTE } from '../../src/core/palette';
import { FRAME_BYTES, HEIGHT, WIDTH } from '../../src/core/protocol';
import { measureText } from '../../src/spike/font';
import { barRects, drawTestCard, LAYOUT, TEST_CARD_TITLE, testCardFrame } from '../../src/spike/testCard';

const STAMP = '2026-10-12 14:03:22';
const BLACK = 0;

function at(pixels: Uint8Array, x: number, y: number): number {
  return pixels[y * WIDTH + x];
}

/** Columns with ink (black) between rows y0 and y1, within x0..x1. */
function inkColumns(pixels: Uint8Array, x0: number, x1: number, y0: number, y1: number): number[] {
  const columns: number[] = [];
  for (let x = x0; x < x1; x++) {
    for (let y = y0; y < y1; y++) {
      if (at(pixels, x, y) === BLACK) {
        columns.push(x);
        break;
      }
    }
  }
  return columns;
}

describe('drawTestCard', () => {
  const card = drawTestCard({ page: 1, stamp: STAMP });

  it('is one palette index per panel pixel, using all seven colours and nothing else', () => {
    expect(card.length).toBe(WIDTH * HEIGHT);
    const used = new Set(card);
    expect([...used].sort()).toEqual(PALETTE.map((colour) => colour.index));
  });

  it('has a black frame along the panel edge', () => {
    for (const [x, y] of [
      [0, 0],
      [WIDTH - 1, 0],
      [0, HEIGHT - 1],
      [WIDTH - 1, HEIGHT - 1],
      [LAYOUT.edge - 1, HEIGHT / 2],
      [WIDTH / 2, HEIGHT - LAYOUT.edge],
    ]) {
      expect(at(card, x, y), `${x},${y}`).toBe(BLACK);
    }
  });

  it('draws seven adjacent bars in palette order', () => {
    const bars = barRects();
    expect(bars).toHaveLength(7);
    expect(bars[0].x).toBe(LAYOUT.bars.x);
    for (let i = 1; i < bars.length; i++) expect(bars[i].x).toBe(bars[i - 1].x + bars[i - 1].width);
    const last = bars[bars.length - 1];
    expect(last.x + last.width).toBe(LAYOUT.bars.x + LAYOUT.bars.width);
    bars.forEach((bar, i) => {
      const centre = at(card, bar.x + Math.floor(bar.width / 2), bar.y + Math.floor(bar.height / 2));
      expect(centre, PALETTE[i].name).toBe(PALETTE[i].index);
    });
  });

  it('prints the title and the stamp where the layout says, within their measured width', () => {
    const titleInk = inkColumns(card, LAYOUT.textX, WIDTH - LAYOUT.edge, LAYOUT.titleY, LAYOUT.titleY + 8 * LAYOUT.titleScale);
    expect(titleInk[0]).toBe(LAYOUT.textX);
    expect(titleInk[titleInk.length - 1]).toBeLessThan(LAYOUT.textX + measureText(TEST_CARD_TITLE, LAYOUT.titleScale));
    const stampInk = inkColumns(card, LAYOUT.textX, WIDTH - LAYOUT.edge, LAYOUT.stampY, LAYOUT.stampY + 8 * LAYOUT.stampScale);
    expect(stampInk.length).toBeGreaterThan(0);
    expect(stampInk[stampInk.length - 1]).toBeLessThan(LAYOUT.textX + measureText(STAMP, LAYOUT.stampScale));
  });

  it('keeps everything inside the panel frame', () => {
    const right = LAYOUT.textX + measureText(TEST_CARD_TITLE, LAYOUT.titleScale);
    expect(right).toBeLessThan(WIDTH - LAYOUT.edge);
    expect(LAYOUT.textX + measureText('2026-12-31 23:59:59', LAYOUT.stampScale)).toBeLessThan(WIDTH - LAYOUT.edge);
    const box = LAYOUT.pageBox;
    expect(box.y + box.height).toBeLessThanOrEqual(HEIGHT - LAYOUT.edge);
  });

  it('is deterministic and differs by page and by stamp', () => {
    expect(drawTestCard({ page: 1, stamp: STAMP })).toEqual(card);
    expect(drawTestCard({ page: 2, stamp: STAMP })).not.toEqual(card);
    expect(drawTestCard({ page: 1, stamp: '2026-10-12 14:03:23' })).not.toEqual(card);
  });

  it('changes only inside the page box when the page changes', () => {
    const other = drawTestCard({ page: 4, stamp: STAMP });
    const box = LAYOUT.pageBox;
    for (let i = 0; i < card.length; i++) {
      if (card[i] === other[i]) continue;
      const x = i % WIDTH;
      const y = Math.floor(i / WIDTH);
      expect(x >= box.x && x < box.x + box.width && y >= box.y && y < box.y + box.height, `${x},${y}`).toBe(true);
    }
  });

  it('rejects pages other than 1-4', () => {
    for (const page of [0, 5, 1.5, Number.NaN]) {
      expect(() => drawTestCard({ page, stamp: STAMP })).toThrow(RangeError);
    }
  });
});

describe('testCardFrame', () => {
  it('is the packed card, FRAME_BYTES long', () => {
    const frame = testCardFrame({ page: 3, stamp: STAMP });
    expect(frame.length).toBe(FRAME_BYTES);
    expect(frame).toEqual(packIndices(drawTestCard({ page: 3, stamp: STAMP })));
  });
});
