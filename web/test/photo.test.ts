import { describe, expect, it } from 'vitest';
import { capSize, isOverLimit, photoSizeFromHeader } from '../src/core/photo';
import { vectorFile } from './vectors';

interface CapVectors {
  pixel_limit: number;
  cap: { name: string; photo: [number, number]; capped: [number, number] }[];
  refusal: { name: string; photo: [number, number]; refused: boolean }[];
}
const vectors = vectorFile<CapVectors>('photo-cap-vectors.json');

const u16 = (n: number) => [(n >> 8) & 255, n & 255];
const u32 = (n: number) => [(n >>> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255];
const ascii = (s: string) => [...s].map((c) => c.charCodeAt(0));

/** A JPEG that has only its headers: an EXIF segment holding a thumbnail's own SOF, then the real SOF. */
function jpeg(width: number, height: number, marker = 0xc0): Uint8Array {
  const exif = [...ascii('Exif'), 0, 0, 0xff, 0xc0, 0, 17, 8, ...u16(9), ...u16(9), 3];
  return Uint8Array.from([
    0xff, 0xd8,
    0xff, 0xe1, ...u16(exif.length + 2), ...exif,
    0xff, 0xdb, ...u16(4), 0, 0, // a segment without a size in it
    0xff, marker, ...u16(17), 8, ...u16(height), ...u16(width), 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
  ]);
}

function png(width: number, height: number): Uint8Array {
  return Uint8Array.from([0x89, ...ascii('PNG'), 0x0d, 0x0a, 0x1a, 0x0a, ...u32(13), ...ascii('IHDR'), ...u32(width), ...u32(height), 8, 6, 0, 0, 0]);
}

const le24 = (n: number) => [n & 255, (n >> 8) & 255, (n >> 16) & 255];

function webpExtended(width: number, height: number): Uint8Array {
  return Uint8Array.from([...ascii('RIFF'), 0, 0, 0, 0, ...ascii('WEBP'), ...ascii('VP8X'), 10, 0, 0, 0, 0, 0, 0, 0, ...le24(width - 1), ...le24(height - 1)]);
}

function webpLossy(width: number, height: number): Uint8Array {
  return Uint8Array.from([...ascii('RIFF'), 0, 0, 0, 0, ...ascii('WEBP'), ...ascii('VP8 '), 10, 0, 0, 0, 0, 0, 0, 0x9d, 0x01, 0x2a, width & 255, width >> 8, height & 255, height >> 8]);
}

function webpLossless(width: number, height: number): Uint8Array {
  const bits = (width - 1) | ((height - 1) << 14);
  return Uint8Array.from([...ascii('RIFF'), 0, 0, 0, 0, ...ascii('WEBP'), ...ascii('VP8L'), 5, 0, 0, 0, 0x2f, bits & 255, (bits >> 8) & 255, (bits >> 16) & 255, (bits >> 24) & 255]);
}

describe('the 4K cap', () => {
  it.each(vectors.cap)('$name', ({ photo, capped }) => {
    expect(capSize(photo[0], photo[1])).toEqual({ width: capped[0], height: capped[1] });
  });
});

describe('the 50 megapixel refusal', () => {
  it.each(vectors.refusal)('$name', ({ photo, refused }) => {
    expect(isOverLimit(photo[0], photo[1])).toBe(refused);
  });
});

describe('the size in a file header', () => {
  it('reads a JPEG past an EXIF thumbnail, progressive or not', () => {
    expect(photoSizeFromHeader(jpeg(8688, 5792))).toEqual({ width: 8688, height: 5792 });
    expect(photoSizeFromHeader(jpeg(4032, 3024, 0xc2))).toEqual({ width: 4032, height: 3024 });
  });

  it('reads PNG and the three WebP kinds', () => {
    expect(photoSizeFromHeader(png(16320, 12240))).toEqual({ width: 16320, height: 12240 });
    expect(photoSizeFromHeader(webpExtended(8000, 6251))).toEqual({ width: 8000, height: 6251 });
    expect(photoSizeFromHeader(webpLossy(1200, 900))).toEqual({ width: 1200, height: 900 });
    expect(photoSizeFromHeader(webpLossless(3000, 2000))).toEqual({ width: 3000, height: 2000 });
  });

  it('does not guess for other formats or a cut-off header', () => {
    expect(photoSizeFromHeader(Uint8Array.from(ascii('....ftypheic')))).toBeUndefined();
    expect(photoSizeFromHeader(jpeg(100, 100).subarray(0, 30))).toBeUndefined();
    expect(photoSizeFromHeader(new Uint8Array(0))).toBeUndefined();
  });
});
