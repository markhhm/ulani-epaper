/**
 * Frames: what the calendar stores for one page.
 *
 * A frame is WIDTH x HEIGHT palette indices, row-major from the top-left, two
 * pixels per byte with the first pixel in the high nibble: FRAME_BYTES bytes.
 * This module packs and unpacks frames, turns panel-sized pictures into
 * frames, and renders frames back for previews.
 */

import { type DitherOptions, toIndices } from './dither';
import { nibbleRgb } from './palette';
import { FRAME_BYTES, HEIGHT, WIDTH } from './protocol';

/**
 * Straight (not premultiplied) RGBA pixels, row-major from the top-left,
 * 4 bytes per pixel: the layout of the DOM's ImageData, which satisfies this
 * interface. Plain objects work too, so tests need no canvas.
 */
export interface RgbaImage {
  readonly width: number;
  readonly height: number;
  /** `width * height * 4` bytes. */
  readonly data: Uint8ClampedArray;
}

/**
 * Two indices per byte, the first in the high nibble. An odd count is padded
 * with a 0 nibble. Each index must be 0-15.
 *
 * @throws RangeError when an index is above 15.
 */
export function packIndices(indices: Uint8Array): Uint8Array {
  const out = new Uint8Array(Math.ceil(indices.length / 2));
  const last = indices.length - 1;
  for (let i = 0, o = 0; i <= last; i += 2, o++) {
    const high = indices[i];
    const low = i < last ? indices[i + 1] : 0;
    if ((high | low) > 15) {
      const at = high > 15 ? i : i + 1;
      throw new RangeError(`index ${indices[at]} at ${at} does not fit in a nibble`);
    }
    out[o] = (high << 4) | low;
  }
  return out;
}

/** Rows per band in whiteBands. */
const BAND_ROWS = 60;
/** Two white pixels (palette index 1). */
const WHITE_BYTE = 0x11;

/**
 * For the diagnostics log: one character per band of 60 rows of a packed
 * frame, top first, `W` when every pixel of the band is white, else `.`.
 * A picture that came out blank shows as a run of `W`.
 */
export function whiteBands(frame: Uint8Array): string {
  const bandBytes = (WIDTH / 2) * BAND_ROWS;
  let map = '';
  for (let start = 0; start < frame.length; start += bandBytes) {
    map += frame.subarray(start, start + bandBytes).every((byte) => byte === WHITE_BYTE) ? 'W' : '.';
  }
  return map;
}

/** Inverse of packIndices: two indices per byte, high nibble first. */
export function unpackIndices(frame: Uint8Array): Uint8Array {
  const out = new Uint8Array(frame.length * 2);
  for (let i = 0, o = 0; i < frame.length; i++, o += 2) {
    const byte = frame[i];
    out[o] = byte >> 4;
    out[o + 1] = byte & 0x0f;
  }
  return out;
}

/**
 * A panel-sized picture (WIDTH x HEIGHT, already fitted and opaque; alpha is
 * ignored) as a frame ready to upload: mapped onto the palette (see
 * dither.toIndices) and packed.
 *
 * @throws RangeError when `image` is not WIDTH x HEIGHT.
 */
export function encodeFrame(image: RgbaImage, options?: DitherOptions): Uint8Array {
  if (image.width !== WIDTH || image.height !== HEIGHT) {
    throw new RangeError(`a frame is ${WIDTH} x ${HEIGHT} pixels, got ${image.width} x ${image.height}`);
  }
  return packIndices(toIndices(image, options));
}

// Opaque RGBA of each of the 16 nibble values, as one 32-bit word per value
// (in the platform's byte order, like the pixel words written with it).
const NIBBLE_RGBA = new Uint8Array(16 * 4);
for (let n = 0; n < 16; n++) {
  NIBBLE_RGBA.set([...nibbleRgb(n), 255], n * 4);
}
const NIBBLE_PIXEL = new Uint32Array(NIBBLE_RGBA.buffer);

/**
 * The frame as the panel shows it, 1:1: opaque RGBA in the panel's colours
 * (palette.nibbleRgb). Nibbles without a palette colour render as its black.
 * Smaller previews are made by preview.previewImage.
 *
 * @throws RangeError when `frame` is not FRAME_BYTES long.
 */
export function previewFrame(frame: Uint8Array): RgbaImage {
  if (frame.length !== FRAME_BYTES) {
    throw new RangeError(`a frame is ${FRAME_BYTES} bytes, got ${frame.length}`);
  }
  const data = new Uint8ClampedArray(WIDTH * HEIGHT * 4);
  const pixels = new Uint32Array(data.buffer);
  for (let i = 0, o = 0; i < frame.length; i++, o += 2) {
    const byte = frame[i];
    pixels[o] = NIBBLE_PIXEL[byte >> 4];
    pixels[o + 1] = NIBBLE_PIXEL[byte & 0x0f];
  }
  return { width: WIDTH, height: HEIGHT, data };
}
