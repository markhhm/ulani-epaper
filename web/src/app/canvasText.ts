/**
 * The bold text of cards, measured and drawn with a canvas (browser only): the layout asks for widths
 * and for the height of 國 above and below the baseline, drawing asks for a line as ink with no
 * partial coverage (the panel has no grey), which `cardRender` then puts down in pure colours.
 *
 * The font is the system's bold Traditional Chinese face; the pages drawn on the device use bundled
 * Noto Sans CJK TC, so widths differ slightly between apps and the line breaks can too.
 */

import type { Mask, TextRasterizer } from '../core/cardRender';
import { makeCanvas } from './photoLoad';

const FAMILY = '"Noto Sans TC", "Noto Sans CJK TC", "PingFang TC", "Microsoft JhengHei", "Heiti TC", "Noto Sans CJK JP", sans-serif';

type Context = OffscreenCanvasRenderingContext2D | CanvasRenderingContext2D;

const MAX_CACHE = 2000;

/** A rasterizer drawing with the system's bold CJK font. */
export function canvasRasterizer(): TextRasterizer {
  let context: Context | undefined;
  const ctx = (size: number): Context => {
    context ??= makeCanvas(8, 8, false).context;
    context.font = `bold ${size}px ${FAMILY}`;
    context.textBaseline = 'alphabetic';
    context.fontKerning = 'none';
    return context;
  };
  const widths = new Map<string, number>();
  const extents = new Map<number, { above: number; below: number }>();
  const masks = new Map<string, Mask>();

  const width = (text: string, size: number): number => {
    const key = `${size}|${text}`;
    let w = widths.get(key);
    if (w === undefined) {
      w = ctx(size).measureText(text).width;
      if (widths.size > MAX_CACHE * 10) widths.clear();
      widths.set(key, w);
    }
    return w;
  };

  const extent = (size: number) => {
    let e = extents.get(size);
    if (!e) {
      const m = ctx(size).measureText('國');
      e = { above: Math.ceil(m.actualBoundingBoxAscent), below: Math.ceil(m.actualBoundingBoxDescent) };
      extents.set(size, e);
    }
    return e;
  };

  const mask = (text: string, size: number): Mask => {
    const key = `${size}|${text}`;
    const kept = masks.get(key);
    if (kept) return kept;
    const pad = Math.ceil(size * 0.3) + 2; // room for glyphs that lean past their advance
    const w = Math.ceil(width(text, size)) + 2 * pad;
    const above = Math.ceil(size * 1.1);
    const h = above + Math.ceil(size * 0.4) + 2;
    const { context: c } = makeCanvas(w, h, false);
    c.font = `bold ${size}px ${FAMILY}`;
    c.textBaseline = 'alphabetic';
    c.fontKerning = 'none';
    c.fillStyle = '#000';
    c.fillText(text, pad, above);
    const data = c.getImageData(0, 0, w, h).data;
    const ink = new Uint8Array(w * h);
    for (let i = 0; i < ink.length; i++) ink[i] = (data[i * 4 + 3] as number) >= 128 ? 1 : 0;
    const result: Mask = { width: w, height: h, originX: pad, baseline: above, ink };
    if (masks.size >= MAX_CACHE / 10) masks.clear();
    masks.set(key, result);
    return result;
  };

  return { width, extent, mask };
}

let shared: TextRasterizer | undefined;

/** The rasterizer the app uses (one, so its measurements and glyphs are kept). */
export function textRasterizer(): TextRasterizer {
  shared ??= canvasRasterizer();
  return shared;
}
