/**
 * The font of the calendar pages (browser only): the bundled Noto Sans CJK TC subset, Regular and Bold
 * (`public/fonts`, the files of the Python app), loaded with `FontFace`. Widths and which characters can be
 * drawn come from the font file itself (`core/otf.ts`), so every app cuts and wraps text in the same places;
 * the canvas only draws the glyphs, one character at a time at those widths, and every pixel is then ink or
 * not (the panel has no grey).
 */

import type { Typeface } from '../core/calendarDraw';
import type { Mask } from '../core/cardRender';
import { metricsOf, readFont } from '../core/otf';
import { makeCanvas } from './photoLoad';

const FAMILY = 'Paperhue Noto Sans TC';
const FILES = { regular: 'NotoSansCJKtc-Regular-subset.otf', bold: 'NotoSansCJKtc-Bold-subset.otf' };
const MAX_MASKS = 400;

async function fetchBytes(file: string): Promise<Uint8Array<ArrayBuffer>> {
  const response = await fetch(`${import.meta.env.BASE_URL}fonts/${file}`);
  if (!response.ok) throw new Error(`the font ${file} did not load (HTTP ${response.status})`);
  return new Uint8Array(await response.arrayBuffer());
}

async function load(): Promise<Typeface> {
  const [regular, bold] = await Promise.all([fetchBytes(FILES.regular), fetchBytes(FILES.bold)]);
  const faces = [new FontFace(FAMILY, regular, { weight: '400' }), new FontFace(FAMILY, bold, { weight: '700' })];
  await Promise.all(faces.map((face) => face.load()));
  for (const face of faces) document.fonts.add(face);

  const metrics = metricsOf(readFont(regular), readFont(bold));
  const masks = new Map<string, Mask>();
  const mask = (text: string, size: number, isBold: boolean): Mask => {
    const key = `${isBold ? 'b' : 'r'}${size}|${text}`;
    const kept = masks.get(key);
    if (kept) return kept;
    const pad = Math.ceil(size * 0.3) + 2; // room for glyphs that lean past their advance
    const above = Math.ceil(size * 1.1);
    const width = metrics.width(text, size, isBold) + 2 * pad;
    const height = above + Math.ceil(size * 0.4) + 2;
    const { context } = makeCanvas(width, height, false);
    context.font = `${isBold ? 700 : 400} ${size}px "${FAMILY}"`;
    context.textBaseline = 'alphabetic';
    context.fillStyle = '#000';
    let x = pad;
    for (const ch of text) {
      context.fillText(ch, x, above);
      x += metrics.width(ch, size, isBold);
    }
    const data = context.getImageData(0, 0, width, height).data;
    const ink = new Uint8Array(width * height);
    for (let i = 0; i < ink.length; i++) ink[i] = (data[i * 4 + 3] as number) >= 128 ? 1 : 0;
    const result: Mask = { width, height, originX: pad, baseline: above, ink };
    if (masks.size >= MAX_MASKS) masks.clear();
    masks.set(key, result);
    return result;
  };
  return { ...metrics, mask };
}

let loaded: Promise<Typeface> | undefined;

/** The font of the calendar pages, loaded once (a failed load is tried again next time). */
export function calendarTypeface(): Promise<Typeface> {
  loaded ??= load().catch((error: unknown) => {
    loaded = undefined;
    throw error;
  });
  return loaded;
}
