/**
 * Where a card's text goes (shared/CARDS.md, "Drawing"): the wrapping and cutting of the pages in
 * Python (layouts.py `_fit`, `_wrap`, `_flow`) and the placement of each text box, as a list of lines
 * with their baseline positions. Pure: the font is whatever `Measure` says, so Node tests use
 * recorded metrics and the browser a canvas. The strings it returns are the ones the Python goldens
 * (shared/layouts/card/golden/*.txt) list.
 */

import { type Card, cleanText, type TextBox } from './cards';
import type { ColourName } from './palette';
import { HEIGHT, WIDTH } from './protocol';

/** The bold font: the advance width of a string, and the extent of a bold 國 around the baseline. */
export interface Measure {
  width(text: string, size: number): number;
  extent(size: number): { above: number; below: number };
}

/** One line of text to draw with its baseline at `y` (panel pixels). */
export interface PlacedLine {
  text: string;
  /** Left edge, right edge or centre of the line, by `anchor`. */
  x: number;
  /** Baseline. */
  y: number;
  anchor: 'left' | 'center' | 'right';
  size: number;
  color: ColourName;
  /** Outline radius in pixels, 0 for none. */
  outline: number;
  outlineColor: ColourName;
}

const ELLIPSIS = '…';
const NOTE_PITCH = 1.25; // line pitch, times the text size
const OUTLINE_DIV = 16;
const LATIN = /[0-9A-Za-zÀ-ɏ]/;
const TOKEN = /[0-9A-Za-zÀ-ɏ'’.,:;!?&+#@%/-]+|\s+|./gsu; // Latin words stay whole
const NO_LINE_START = new Set(Array.from('，。、：；！？）」』》〉】,.:;!?)'));

/** A screen fraction in pixels, halves up (the same in every implementation). */
function px(fraction: number, total: number): number {
  return Math.floor(fraction * total + 0.5);
}

/** The pixel box of a text box: x0, y0, x1, y1. */
export function pixelBox(box: readonly [number, number, number, number]): { x0: number; y0: number; x1: number; y1: number } {
  return { x0: px(box[0], WIDTH), y0: px(box[1], HEIGHT), x1: px(box[0] + box[2], WIDTH), y1: px(box[1] + box[3], HEIGHT) };
}

/** Outline radius in pixels for a font size. */
export function outlineRadius(size: number): number {
  return Math.max(1, Math.floor(size / OUTLINE_DIV + 0.5));
}

/** Where an outline of radius `r` draws the text: every (dx, dy) with dx² + dy² <= r² + r. */
export function outlineOffsets(r: number): [number, number][] {
  const out: [number, number][] = [];
  for (let dy = -r; dy <= r; dy++) for (let dx = -r; dx <= r; dx++) if (dx * dx + dy * dy <= r * r + r) out.push([dx, dy]);
  return out;
}

export type Width = (text: string) => number;

/** `text` cut with an ellipsis to at most `width` px, never mid Latin word. */
export function fit(text: string, width: number, w: Width): string {
  if (w(text) <= width) return text;
  const chars = Array.from(text);
  let lo = 0;
  let hi = chars.length;
  while (lo < hi) {
    const mid = Math.floor((lo + hi + 1) / 2);
    if (w(chars.slice(0, mid).join('').trimEnd() + ELLIPSIS) <= width) lo = mid;
    else hi = mid - 1;
  }
  if (lo === 0) return w(ELLIPSIS) <= width ? ELLIPSIS : '';
  const next = chars[lo];
  if (next !== undefined && LATIN.test(chars[lo - 1] as string) && LATIN.test(next)) {
    const space = chars.slice(0, lo).lastIndexOf(' ');
    if (space > 0 && chars.slice(0, space).join('').trim()) lo = space;
  }
  return chars.slice(0, lo).join('').trimEnd() + ELLIPSIS;
}

/** Greedy wrap into at most `maxLines` lines; the last one gets '…' if cut. */
export function wrap(text: string, width: number, maxLines: number, w: Width): string[] {
  const pieces: string[] = [];
  for (const tok of text.match(TOKEN) ?? []) {
    if (!/^\s+$/.test(tok) && Array.from(tok).length > 1 && w(tok) > width) pieces.push(...Array.from(tok));
    else pieces.push(tok);
  }
  const lines: string[][] = [[]];
  for (const piece of pieces) {
    const line = lines[lines.length - 1] as string[];
    const cur = line.join('');
    if (!cur.trim() || w((cur + piece).trimEnd()) <= width) {
      line.push(piece);
    } else if (NO_LINE_START.has(piece)) {
      // Punctuation may not start a line: carry the previous character down with it.
      const last = line[line.length - 1] as string;
      if (line.length > 1 && !/^\s+$/.test(last)) lines.push([line.pop() as string, piece]);
      else line.push(piece);
    } else {
      lines.push(/^\s+$/.test(piece) ? [] : [piece]);
    }
  }
  let out = lines.map((line) => line.join('').trim()).filter(Boolean);
  if (out.length > maxLines) {
    const rest = lines.slice(maxLines - 1).map((line) => line.join('')).join('').trim();
    out = [...out.slice(0, maxLines - 1), fit(rest, width, w)];
  }
  return out.map((line) => fit(line, width, w));
}

/** Wrap paragraphs into at most `maxLines` lines; when something is left out the last line ends with '…'. */
function flow(paras: string[], width: number, maxLines: number, w: Width): string[] {
  const lines: string[] = [];
  for (const para of paras) {
    const room = maxLines - lines.length;
    const whole = wrap(para, width, 1e6, w);
    if (whole.length <= room) {
      lines.push(...whole);
      continue;
    }
    if (room > 0) lines.push(...wrap(para, width, room, w));
    else lines[lines.length - 1] = fit((lines[lines.length - 1] as string) + ELLIPSIS, width, w);
    return lines;
  }
  return lines;
}

function layoutText(t: TextBox, measure: Measure): PlacedLine[] {
  const outline = t.outline ? outlineRadius(t.size) : 0;
  const { x0, y0, x1, y1 } = pixelBox(t.box);
  const left = x0 + outline;
  const top = y0 + outline;
  const right = x1 - outline;
  const bottom = y1 - outline;
  const paras = t.text.split('\n').map(cleanText).filter(Boolean);
  if (paras.length === 0 || right <= left) return [];
  const { above, below } = measure.extent(t.size);
  const pitch = t.size * NOTE_PITCH;
  const maxLines = Math.max(1, Math.floor((bottom - top - above - below) / pitch) + 1); // one line is always drawn
  const w: Width = (text) => measure.width(text, t.size);
  const lines = flow(paras, right - left, maxLines, w);
  const x = t.align === 'left' ? left : t.align === 'right' ? right : Math.floor((left + right) / 2);
  return lines.map((text, i) => ({
    text,
    x,
    y: top + above + Math.floor(i * pitch + 0.5),
    anchor: t.align,
    size: t.size,
    color: t.color,
    outline,
    outlineColor: t.outline_color,
  }));
}

/** Every line of every text box of `card`, in drawing order. */
export function layoutCard(card: Card, measure: Measure): PlacedLine[] {
  return card.texts.flatMap((t) => layoutText(t, measure));
}

/**
 * The height, as a fraction of the screen, of a box that shows all of `t.text` at `t.size` when it is
 * `width` wide (also a fraction) and starts at `y`: what an editor gives a box as tall as its text. At
 * most down to the bottom of the screen.
 */
export function fitBoxHeight(t: Pick<TextBox, 'text' | 'size' | 'outline'>, width: number, y: number, measure: Measure): number {
  const outline = t.outline ? outlineRadius(t.size) : 0;
  const paras = t.text.split('\n').map(cleanText).filter(Boolean);
  const { above, below } = measure.extent(t.size);
  const area = Math.max(1, Math.round(width * WIDTH) - 2 * outline);
  const lines = paras.length === 0 ? 1 : flow(paras, area, 1e6, (text) => measure.width(text, t.size)).length;
  // Two pixels of slack: the box's edges are rounded to pixels separately.
  const pixels = 2 * outline + above + below + Math.ceil((lines - 1) * t.size * NOTE_PITCH) + 2;
  return Math.min(pixels / HEIGHT, 1 - y);
}
