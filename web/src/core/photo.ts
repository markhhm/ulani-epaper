/**
 * The size rules every photo goes through (shared/CROP.md, "Photo size"):
 * a photo over 50 megapixels is refused, anything else is shrunk to fit 4K
 * (3840 x 2160 in its own orientation) and never enlarged. Pure functions
 * here; decoding is in app/photoLoad.ts.
 */

/** A photo with more pixels than this is refused instead of shrunk. */
export const PHOTO_PIXEL_LIMIT = 50_000_000;

/** The cap box of a landscape photo; a portrait photo gets it turned round. */
export const MAX_PHOTO_SIZE = Object.freeze({ width: 3840, height: 2160 });

/** The photo is over PHOTO_PIXEL_LIMIT: the user shrinks it and chooses it again. */
export class PhotoTooLarge extends Error {
  override name = 'PhotoTooLarge';
  constructor() {
    super(`the photo is over the ${PHOTO_PIXEL_LIMIT / 1_000_000} megapixel limit; shrink it first`);
  }
}

export interface Size {
  readonly width: number;
  readonly height: number;
}

/** Exactly PHOTO_PIXEL_LIMIT pixels is accepted. */
export function isOverLimit(width: number, height: number): boolean {
  return width * height > PHOTO_PIXEL_LIMIT;
}

/**
 * `width` x `height` shrunk, keeping its shape, to fit the cap box in the
 * same orientation (a square counts as landscape). The binding side is the
 * box edge, the other one is rounded with halves up and is at least 1.
 */
export function capSize(width: number, height: number): Size {
  const boxW = width >= height ? MAX_PHOTO_SIZE.width : MAX_PHOTO_SIZE.height;
  const boxH = width >= height ? MAX_PHOTO_SIZE.height : MAX_PHOTO_SIZE.width;
  if (width <= boxW && height <= boxH) return { width, height };
  if (boxW * height <= boxH * width) {
    return { width: boxW, height: Math.max(1, Math.floor((2 * height * boxW + width) / (2 * width))) };
  }
  return { width: Math.max(1, Math.floor((2 * width * boxH + height) / (2 * height))), height: boxH };
}

const u16 = (b: Uint8Array, at: number) => (b[at] << 8) | b[at + 1];
const u32 = (b: Uint8Array, at: number) => ((b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]) >>> 0;
const text = (b: Uint8Array, at: number, n: number) => String.fromCharCode(...b.subarray(at, at + n));

function jpegSize(b: Uint8Array): Size | undefined {
  let at = 2;
  while (at + 4 <= b.length) {
    if (b[at] !== 0xff) return undefined;
    const marker = b[at + 1];
    if (marker === 0xff) {
      at += 1; // fill byte
      continue;
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      at += 2; // markers without a length
      continue;
    }
    const isFrame = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isFrame) {
      if (at + 9 > b.length) return undefined;
      return { width: u16(b, at + 7), height: u16(b, at + 5) };
    }
    at += 2 + u16(b, at + 2);
  }
  return undefined;
}

function webpSize(b: Uint8Array): Size | undefined {
  if (b.length < 25) return undefined;
  const kind = text(b, 12, 4);
  if (kind === 'VP8X' && b.length >= 30) {
    return { width: 1 + (b[24] | (b[25] << 8) | (b[26] << 16)), height: 1 + (b[27] | (b[28] << 8) | (b[29] << 16)) };
  }
  if (kind === 'VP8 ' && b.length >= 30 && b[23] === 0x9d && b[24] === 0x01 && b[25] === 0x2a) {
    return { width: (b[26] | (b[27] << 8)) & 0x3fff, height: (b[28] | (b[29] << 8)) & 0x3fff };
  }
  if (kind === 'VP8L' && b[20] === 0x2f) {
    const bits = (b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24)) >>> 0;
    return { width: 1 + (bits & 0x3fff), height: 1 + ((bits >>> 14) & 0x3fff) };
  }
  return undefined;
}

/**
 * Width and height written in the first bytes of a JPEG, PNG or WebP file,
 * read without decoding a pixel (the EXIF orientation does not change their
 * product). Undefined for other formats or a header that is cut off: the
 * caller then checks the size after decoding.
 */
export function photoSizeFromHeader(bytes: Uint8Array): Size | undefined {
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) return jpegSize(bytes);
  if (bytes.length >= 24 && u32(bytes, 0) === 0x89504e47 && text(bytes, 12, 4) === 'IHDR') {
    return { width: u32(bytes, 16), height: u32(bytes, 20) };
  }
  if (bytes.length >= 12 && text(bytes, 0, 4) === 'RIFF' && text(bytes, 8, 4) === 'WEBP') return webpSize(bytes);
  return undefined;
}

/** The browser cannot open the file as a photo (not a photo, or damaged). */
export class PhotoUnreadable extends Error {
  override name = 'PhotoUnreadable';
  constructor(options?: { cause?: unknown }) {
    super('this file cannot be opened as a photo', options);
  }
}
