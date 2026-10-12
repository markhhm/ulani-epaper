/**
 * What the calendar pages draw with (shared/LAYOUTS.md, "Drawing primitives"): one 800 x 480 picture
 * of palette indices, with text and shapes drawn aliased in pure panel colours, and the same
 * primitives in the "on a photo" form (section 12): white text with a black outline, colour marks
 * outlined in black.
 *
 * Shapes are filled by testing each pixel's centre, so there is no anti-aliasing. The glyphs come from
 * a `Typeface` (the bundled fonts through a canvas in the browser, boxes in tests).
 */

import { fit, outlineOffsets, outlineRadius } from './cardLayout';
import { type Mask, stamp } from './cardRender';
import { clean } from './otf';
import { COLOURS, type ColourName } from './palette';
import { HEIGHT, WIDTH } from './protocol';

/** The font of the pages. */
export interface Typeface {
  /** The advance of `text` in px (whole pixels per character, as Pillow measures the bundled fonts). */
  width(text: string, size: number, bold: boolean): number;
  /** The character has a glyph. */
  has(codePoint: number): boolean;
  /** `text` as ink, each character `width` apart. */
  mask(text: string, size: number, bold: boolean): Mask;
}

const PHOTO_OUTLINE_MAX = 4; // text on a photo: outline radius at most this (the big numerals)

type Anchor = 'ls' | 'rs' | 'ms';

export interface TextOptions {
  bold?: boolean;
  fill?: ColourName;
  /** `ls` the text starts at x, `rs` it ends there, `ms` it is centred on it; always on the baseline y. */
  anchor?: Anchor;
  /** Cut with "…" to at most this many px. */
  maxw?: number;
}

type Test = (x: number, y: number) => boolean;
type Box = readonly [x0: number, y0: number, x1: number, y1: number];

/** The ellipse in a box (inclusive corners). */
function ellipse([x0, y0, x1, y1]: Box): Test {
  const cx = (x0 + x1 + 1) / 2;
  const cy = (y0 + y1 + 1) / 2;
  const rx = (x1 - x0 + 1) / 2;
  const ry = (y1 - y0 + 1) / 2;
  return (x, y) => rx > 0 && ry > 0 && ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1;
}

/** The rounded rectangle in a box (inclusive corners). */
function roundRect([x0, y0, x1, y1]: Box, radius: number): Test {
  const r = Math.max(0, Math.min(radius, (x1 - x0 + 1) / 2, (y1 - y0 + 1) / 2));
  return (x, y) => {
    const px = x + 0.5;
    const py = y + 0.5;
    const qx = px < x0 + r ? x0 + r - px : px > x1 + 1 - r ? px - (x1 + 1 - r) : 0;
    const qy = py < y0 + r ? y0 + r - py : py > y1 + 1 - r ? py - (y1 + 1 - r) : 0;
    return qx * qx + qy * qy <= r * r;
  };
}

const grow = ([x0, y0, x1, y1]: Box, by: number): Box => [x0 - by, y0 - by, x1 + by, y1 + by];

export class Page {
  /** The picture, `indices[y * 800 + x]`. */
  readonly indices = new Uint8Array(WIDTH * HEIGHT);
  /** The page is drawn on a photo. */
  readonly photo: boolean;
  /** Every string drawn, in order (what the goldens list). */
  readonly drawn: string[] = [];

  /** A white page, or one on `background` (800 x 480 palette indices, copied). */
  constructor(
    readonly face: Typeface,
    background: Uint8Array | null,
  ) {
    this.photo = background !== null;
    if (background === null) this.indices.fill(COLOURS.white.index);
    else if (background.length === this.indices.length) this.indices.set(background);
    else throw new RangeError('a page background is 800 x 480 pixels');
  }

  private paint(box: Box, test: Test, colour: ColourName, except?: Test): void {
    const index = COLOURS[colour].index;
    const [x0, y0, x1, y1] = box;
    for (let y = Math.max(0, y0); y <= Math.min(HEIGHT - 1, y1); y++) {
      for (let x = Math.max(0, x0); x <= Math.min(WIDTH - 1, x1); x++) {
        if (test(x, y) && !except?.(x, y)) this.indices[y * WIDTH + x] = index;
      }
    }
  }

  clean(text: string): string {
    return clean(text, this.face.has);
  }

  width(text: string, size: number, bold = false): number {
    return this.face.width(text, size, bold);
  }

  /** Draw `raw` (cleaned of what the font lacks) with its baseline at `y`; returns the width drawn. */
  text(x: number, y: number, raw: string, size: number, o: TextOptions = {}): number {
    const bold = o.bold ?? false;
    const measure = (t: string) => this.face.width(t, size, bold);
    let s = this.clean(raw);
    if (o.maxw !== undefined) s = fit(s, o.maxw, measure);
    if (!s) return 0;
    const width = measure(s);
    const xi = Math.round(x);
    const yi = Math.round(y);
    const anchor = o.anchor ?? 'ls';
    const left = anchor === 'rs' ? xi - width : anchor === 'ms' ? Math.round(xi - width / 2) : xi;
    const mask = this.face.mask(s, size, bold);
    if (this.photo) {
      const black = COLOURS.black.index;
      for (const [dx, dy] of outlineOffsets(Math.min(PHOTO_OUTLINE_MAX, outlineRadius(size)))) stamp(this.indices, mask, left + dx, yi + dy, black);
    }
    stamp(this.indices, mask, left, yi, COLOURS[this.photo ? 'white' : (o.fill ?? 'black')].index);
    this.drawn.push(s);
    return width;
  }

  /** A calendar colour bar (rounded). Pale yellow gets a black keyline; on a photo every bar is outlined. */
  bar(x: number, y0: number, y1: number, colour: ColourName, w: number): void {
    const radius = Math.floor(w / 2);
    const box: Box = [x, y0, x + w - 1, y1];
    if (this.photo) {
      const outer = grow(box, 1);
      this.paint(outer, roundRect(outer, radius + 1), 'black');
    }
    if (colour === 'yellow' && !this.photo) {
      this.paint(box, roundRect(box, radius), 'black');
      const inner = grow(box, -1);
      this.paint(inner, roundRect(inner, Math.max(0, radius - 1)), colour);
    } else {
      this.paint(box, roundRect(box, radius), colour);
    }
  }

  private discBox(cx: number, cy: number, r: number): Box {
    return [Math.round(cx - r), Math.round(cy - r), Math.round(cx + r) - 1, Math.round(cy + r) - 1];
  }

  /** A calendar colour dot. Pale yellow gets a black keyline; on a photo every dot is outlined. */
  dot(cx: number, cy: number, r: number, colour: ColourName): void {
    if (this.photo) this.disc(cx, cy, r + 1, 'black');
    const box = this.discBox(cx, cy, r);
    if (colour === 'yellow' && !this.photo) {
      this.paint(box, ellipse(box), 'black');
      this.paint(grow(box, -1), ellipse(grow(box, -1)), colour);
    } else {
      this.paint(box, ellipse(box), colour);
    }
  }

  /** A filled circle (outlined in black on a photo, unless it is black). */
  disc(cx: number, cy: number, r: number, colour: ColourName): void {
    if (this.photo && colour !== 'black') this.disc(cx, cy, r + 1, 'black');
    const box = this.discBox(cx, cy, r);
    this.paint(box, ellipse(box), colour);
  }

  /** A circle outline `width` px wide; on a photo it gets a black outline, and black ink becomes white. */
  ring(cx: number, cy: number, r: number, colour: ColourName, width = 2): void {
    const box = this.discBox(cx, cy, r);
    const ring = (b: Box, w: number, c: ColourName) => this.paint(b, ellipse(b), c, ellipse(grow(b, -w)));
    if (this.photo) {
      ring(grow(box, 1), width + 2, 'black');
      if (colour === 'black') colour = 'white';
    }
    ring(box, width, colour);
  }

  rect(x0: number, y0: number, x1: number, y1: number, colour: ColourName = 'black'): void {
    const box: Box = [x0, y0, x1, y1];
    this.paint(box, () => true, colour);
  }

  /** A line through `points`, `width` px thick. */
  line(points: readonly (readonly [number, number])[], colour: ColourName, width: number): void {
    const index = COLOURS[colour].index;
    const brush = (bx: number, by: number) => {
      for (let dy = 0; dy < width; dy++) {
        for (let dx = 0; dx < width; dx++) {
          if ((dx + 0.5 - width / 2) ** 2 + (dy + 0.5 - width / 2) ** 2 > (width / 2) ** 2) continue;
          const x = bx + dx - Math.floor(width / 2);
          const y = by + dy - Math.floor(width / 2);
          if (x >= 0 && x < WIDTH && y >= 0 && y < HEIGHT) this.indices[y * WIDTH + x] = index;
        }
      }
    };
    for (let i = 1; i < points.length; i++) {
      const [ax, ay] = points[i - 1] as readonly [number, number];
      const [bx, by] = points[i] as readonly [number, number];
      const steps = Math.max(Math.abs(bx - ax), Math.abs(by - ay), 1);
      for (let s = 0; s <= steps; s++) brush(Math.round(ax + ((bx - ax) * s) / steps), Math.round(ay + ((by - ay) * s) / steps));
    }
  }

  /** The "+" mark (2 px strokes, `size` wide) with its left edge at `px`, centred on row `dy`. */
  plus(px: number, dy: number, size: number): void {
    const half = Math.floor(size / 2);
    const strokes: Box[] = [
      [px, dy - 1, px + size - 1, dy],
      [px + half - 1, dy - half - 1, px + half, dy + half - 1],
    ];
    for (const s of strokes) if (this.photo) this.paint(grow(s, 1), () => true, 'black');
    for (const s of strokes) this.paint(s, () => true, this.photo ? 'white' : 'black');
  }

  private hairline(points: [number, number][], side: [number, number]): void {
    if (this.photo) {
      for (const [x, y] of points) for (const k of [-1, 1]) this.rect(x + side[0] * k, y + side[1] * k, x + side[0] * k, y + side[1] * k, 'black');
    }
    for (const [x, y] of points) this.rect(x, y, x, y, this.photo ? 'white' : 'black');
  }

  /** A "grey" line: every other pixel (white between black dots on a photo). */
  hairlineH(x0: number, x1: number, y: number): void {
    const points: [number, number][] = [];
    for (let x = x0; x <= x1; x += 2) points.push([x, y]);
    this.hairline(points, [0, 1]);
  }

  hairlineV(x: number, y0: number, y1: number): void {
    const points: [number, number][] = [];
    for (let y = y0; y <= y1; y += 2) points.push([x, y]);
    this.hairline(points, [1, 0]);
  }
}
