/**
 * The photo crop (shared/CROP.md): the part of a photo that fills the
 * 800 x 480 screen, as fractions `[left, top, width, height]` of the photo
 * after EXIF orientation, always in the screen's 5:3 shape in pixels. All
 * pixel rules are measured on the photo after the 4K cap (core/photo.ts).
 */

import { HEIGHT, WIDTH } from './protocol';

export type Crop = readonly [left: number, top: number, width: number, height: number];

/** A crop is at least this many photo pixels high (or the default's height when that is less) ... */
export const MIN_CROP_PX = 100;
/** ... and at least 1/8 of the default crop's width. */
export const MAX_ZOOM = 8;

const ASPECT = WIDTH / HEIGHT;
const EPS = 1e-9;

/** The largest centred rectangle in the screen's shape: what Fill shows without a crop. */
export function defaultCrop(width: number, height: number): Crop {
  if (width / height > ASPECT) {
    const w = (height * ASPECT) / width;
    return [(1 - w) / 2, 0, w, 1];
  }
  const h = width / ASPECT / height;
  return [0, (1 - h) / 2, 1, h];
}

/** `crop` in the pixels of a `width` x `height` image, rounding halves up like the other apps. */
export function cropBox(crop: Crop, width: number, height: number): [number, number, number, number] {
  const [left, top, w, h] = crop;
  const round = (v: number) => Math.floor(v + 0.5);
  return [round(left * width), round(top * height), round((left + w) * width), round((top + h) * height)];
}

/** The widest (the default's) and narrowest crop width, as fractions, that a `width` x `height` photo allows. */
function widthBounds(width: number, height: number): { max: number; min: number } {
  const max = defaultCrop(width, height)[2];
  const minHeightPx = Math.min(MIN_CROP_PX, defaultCrop(width, height)[3] * height);
  return { max, min: Math.min(max, Math.max(max / MAX_ZOOM, (minHeightPx * ASPECT) / width)) };
}

/** The height fraction that goes with a width fraction in the screen's shape. */
function heightFor(w: number, width: number, height: number): number {
  return (w * width) / (height * ASPECT);
}

/** `crop` if it suits a `width` x `height` photo, else a RangeError. */
export function checkCrop(crop: readonly number[], width: number, height: number): Crop {
  if (crop.length !== 4 || !crop.every((v) => typeof v === 'number' && Number.isFinite(v))) {
    throw new RangeError(`a crop is four numbers (left, top, width, height), got ${JSON.stringify(crop)}`);
  }
  const [left, top, w, h] = crop as [number, number, number, number];
  if (left < 0 || top < 0 || w <= 0 || h <= 0 || left + w > 1 + EPS || top + h > 1 + EPS) {
    throw new RangeError(`the crop must lie inside the photo (fractions 0-1), got ${JSON.stringify(crop)}`);
  }
  if (Math.abs(w * width - h * height * ASPECT) > 1) {
    throw new RangeError(`the crop must have the screen's ${WIDTH}:${HEIGHT} shape, got ${w * width} x ${h * height} px`);
  }
  const d = defaultCrop(width, height);
  if (h * height < Math.min(MIN_CROP_PX, d[3] * height) - 1e-6 || w < d[2] / MAX_ZOOM - EPS) {
    throw new RangeError(`the crop is too small (at most ${MAX_ZOOM}x zoom and at least ${MIN_CROP_PX} photo pixels high)`);
  }
  return [left, top, w, h];
}

/** `crop` moved to `left`, `top` as far as the photo allows. */
function place(left: number, top: number, w: number, h: number): Crop {
  return [Math.min(Math.max(left, 0), 1 - w), Math.min(Math.max(top, 0), 1 - h), w, h];
}

/** `crop` moved by a fraction of the photo, never out of it. */
export function moveCrop(crop: Crop, _width: number, _height: number, dx: number, dy: number): Crop {
  return place(crop[0] + dx, crop[1] + dy, crop[2], crop[3]);
}

/**
 * `crop` zoomed in by `factor` (above 1 shows less of the photo), keeping the photo point `anchor`
 * (default the crop's centre) where it is inside the frame. Zooming stops at the widest (the
 * default) and the narrowest crop the photo allows.
 */
export function zoomCrop(crop: Crop, width: number, height: number, factor: number, anchor?: readonly [number, number]): Crop {
  const { max, min } = widthBounds(width, height);
  const w = Math.min(max, Math.max(min, crop[2] / factor));
  const h = heightFor(w, width, height);
  const [ax, ay] = anchor ?? [crop[0] + crop[2] / 2, crop[1] + crop[3] / 2];
  return place(ax - ((ax - crop[0]) * w) / crop[2], ay - ((ay - crop[1]) * h) / crop[3], w, h);
}

/** How far in a `width` x `height` photo can be zoomed: 1 (the default crop) up to this. */
export function maxZoom(width: number, height: number): number {
  const { max, min } = widthBounds(width, height);
  return max / min;
}
