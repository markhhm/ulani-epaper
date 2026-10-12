/**
 * Fitting pictures to the 800 x 480 panel.
 *
 * The geometry (fitPlacement) and alpha flattening (flattenOnWhite) are pure
 * and testable in Node. Decoding and resampling use the browser's image
 * decoder and canvas (decodePicture, fitToPanel), which exist in browsers and
 * in the Android WebView but not in Vitest's Node environment.
 */

import type { RgbaImage } from './frame';
import { DeviceError, HEIGHT, WIDTH } from './protocol';

/**
 * How a picture is fitted:
 * - `cover`: fill the panel, cropping the centre to the panel's aspect ratio
 *   (the default for photos).
 * - `contain`: show the whole picture, letterboxed on white.
 * - `stretch`: scale both axes to the panel, ignoring the aspect ratio.
 */
export type FitMode = 'cover' | 'contain' | 'stretch';

export const DEFAULT_FIT: FitMode = 'cover';

/** A rectangle in pixels; may be fractional where noted. */
export interface Rect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** Where a picture goes: draw `source` (in picture pixels) into `target` (in panel pixels). */
export interface Placement {
  readonly source: Rect;
  readonly target: Rect;
}

export interface PanelSize {
  readonly width: number;
  readonly height: number;
}

const PANEL: PanelSize = Object.freeze({ width: WIDTH, height: HEIGHT });

/** Python's round(): to the nearest integer, halves to the even neighbour. */
function roundHalfEven(value: number): number {
  const floor = Math.floor(value);
  const fraction = value - floor;
  if (fraction > 0.5) return floor + 1;
  if (fraction < 0.5) return floor;
  return floor % 2 === 0 ? floor : floor + 1;
}

function isPositive(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

/**
 * Geometry of fitting a `sourceWidth` x `sourceHeight` picture to `panel`
 * (default WIDTH x HEIGHT):
 * - `cover`: source = the largest centred region with the panel's aspect
 *   ratio (fractional coordinates allowed); target = the whole panel.
 * - `contain`: scale = min(panel.width / w, panel.height / h); the target size
 *   is round-half-to-even(w * scale) x round-half-to-even(h * scale), each
 *   clamped to 1..panel size, centred with offsets
 *   floor((panel - size) / 2); source = the whole picture. The rest of the
 *   panel is white.
 * - `stretch`: the whole picture onto the whole panel.
 *
 * @throws RangeError when a source dimension is not positive, or the panel
 *   size is not a positive whole number of pixels.
 */
export function fitPlacement(sourceWidth: number, sourceHeight: number, mode: FitMode, panel: PanelSize = PANEL): Placement {
  if (!isPositive(sourceWidth) || !isPositive(sourceHeight)) {
    throw new RangeError(`picture size must be positive, got ${sourceWidth} x ${sourceHeight}`);
  }
  const { width: pw, height: ph } = panel;
  if (!Number.isInteger(pw) || !Number.isInteger(ph) || pw <= 0 || ph <= 0) {
    throw new RangeError(`panel size must be positive whole pixels, got ${pw} x ${ph}`);
  }
  const whole: Rect = { x: 0, y: 0, width: sourceWidth, height: sourceHeight };
  const fullPanel: Rect = { x: 0, y: 0, width: pw, height: ph };

  switch (mode) {
    case 'stretch':
      return { source: whole, target: fullPanel };
    case 'cover': {
      // Same floating-point steps as Pillow's ImageOps.fit (no bleed,
      // centred), so the crop box matches the Python reference exactly.
      const sourceRatio = sourceWidth / sourceHeight;
      const panelRatio = pw / ph;
      let width = sourceWidth;
      let height = sourceHeight;
      if (sourceRatio === panelRatio) {
        // already the panel's shape
      } else if (sourceRatio >= panelRatio) {
        width = panelRatio * sourceHeight; // wider: crop the sides
      } else {
        height = sourceWidth / panelRatio; // taller: crop top and bottom
      }
      const x = (sourceWidth - width) * 0.5;
      const y = (sourceHeight - height) * 0.5;
      return { source: { x, y, width, height }, target: fullPanel };
    }
    case 'contain': {
      const scale = Math.min(pw / sourceWidth, ph / sourceHeight);
      const width = Math.max(1, Math.min(pw, roundHalfEven(sourceWidth * scale)));
      const height = Math.max(1, Math.min(ph, roundHalfEven(sourceHeight * scale)));
      const x = Math.floor((pw - width) / 2);
      const y = Math.floor((ph - height) / 2);
      return { source: whole, target: { x, y, width, height } };
    }
    default:
      throw new RangeError(`unknown fit mode: ${String(mode satisfies never)}`);
  }
}

/** Integer a / 255 rounded to the nearest, for 0 <= a <= 255 * 255. */
function div255(a: number): number {
  const t = a + 128;
  return ((t >> 8) + t) >> 8;
}

/**
 * A copy of `image` composited onto opaque white (straight alpha), so
 * transparent areas print as white rather than black. Alpha becomes 255.
 * Each channel becomes round((c * a + 255 * (255 - a)) / 255).
 *
 * @throws RangeError when `data` does not match the size.
 */
export function flattenOnWhite(image: RgbaImage): RgbaImage {
  const { width, height, data } = image;
  if (data.length !== width * height * 4) {
    throw new RangeError(`a ${width} x ${height} RGBA image has ${width * height * 4} bytes, got ${data.length}`);
  }
  const out = new Uint8ClampedArray(data.length);
  for (let o = 0; o < data.length; o += 4) {
    const a = data[o + 3];
    const white = 255 * (255 - a);
    out[o] = div255(data[o] * a + white);
    out[o + 1] = div255(data[o + 1] * a + white);
    out[o + 2] = div255(data[o + 2] * a + white);
    out[o + 3] = 255;
  }
  return { width, height, data: out };
}

export interface DecodeOptions {
  /**
   * Decode large photos scaled down so their long side is at most this many
   * pixels (default: twice the panel's long side), keeping memory low on
   * phones. Pictures are never scaled up.
   */
  readonly maxLongSide?: number;
}

/** createImageBitmap with the EXIF orientation applied. */
async function orientedBitmap(source: ImageBitmapSource, options: ImageBitmapOptions = {}): Promise<ImageBitmap> {
  try {
    return await createImageBitmap(source, { ...options, imageOrientation: 'from-image' });
  } catch (error) {
    // Engines that predate the 'from-image' value reject it as a TypeError;
    // their default already follows the EXIF orientation.
    if (!(error instanceof TypeError)) throw error;
    return await createImageBitmap(source, options);
  }
}

/**
 * Decode an image file (JPEG, PNG, HEIC where the browser supports it, ...)
 * with its EXIF orientation applied. Browser only.
 *
 * @throws DeviceError when the browser cannot decode the file.
 * @throws RangeError when `maxLongSide` is not a positive integer.
 */
export async function decodePicture(file: Blob, options: DecodeOptions = {}): Promise<ImageBitmap> {
  const maxLongSide = options.maxLongSide ?? 2 * Math.max(WIDTH, HEIGHT);
  if (!Number.isInteger(maxLongSide) || maxLongSide <= 0) {
    throw new RangeError(`maxLongSide must be a positive integer, got ${maxLongSide}`);
  }
  let bitmap: ImageBitmap;
  try {
    bitmap = await orientedBitmap(file);
  } catch (cause) {
    throw new DeviceError('This picture cannot be opened (unsupported or damaged file).', { cause });
  }
  const longSide = Math.max(bitmap.width, bitmap.height);
  if (longSide <= maxLongSide) return bitmap;
  const scale = maxLongSide / longSide;
  try {
    // The bitmap is already upright, so no orientation option here.
    return await createImageBitmap(bitmap, {
      resizeWidth: Math.max(1, Math.round(bitmap.width * scale)),
      resizeHeight: Math.max(1, Math.round(bitmap.height * scale)),
      resizeQuality: 'high',
    });
  } catch (cause) {
    throw new DeviceError('This picture is too large to open on this device.', { cause });
  } finally {
    bitmap.close();
  }
}

type Canvas2D = OffscreenCanvasRenderingContext2D | CanvasRenderingContext2D;

function panelContext(width: number, height: number): Canvas2D {
  const settings: CanvasRenderingContext2DSettings = { alpha: false, willReadFrequently: true };
  let context: Canvas2D | null;
  if (typeof OffscreenCanvas !== 'undefined') {
    context = new OffscreenCanvas(width, height).getContext('2d', settings);
  } else {
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    context = canvas.getContext('2d', settings);
  }
  if (!context) throw new DeviceError('This browser cannot draw pictures (no 2D canvas).');
  return context;
}

/**
 * Draw `picture` onto a white panel-sized canvas according to `mode` (see
 * fitPlacement) with high-quality resampling, and return the opaque pixels.
 * Browser only.
 */
export function fitToPanel(picture: ImageBitmap, mode: FitMode = DEFAULT_FIT, panel: PanelSize = PANEL): RgbaImage {
  const { source, target } = fitPlacement(picture.width, picture.height, mode, panel);
  const context = panelContext(panel.width, panel.height);
  context.fillStyle = '#ffffff';
  context.fillRect(0, 0, panel.width, panel.height);
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = 'high';
  context.drawImage(
    picture,
    source.x, source.y, source.width, source.height,
    target.x, target.y, target.width, target.height,
  );
  // Drawn over opaque white, so every pixel is already opaque.
  return context.getImageData(0, 0, panel.width, panel.height);
}
