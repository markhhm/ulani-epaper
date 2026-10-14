import { describe, expect, it } from 'vitest';
import { encodeFrame, packIndices, previewFrame, unpackIndices, whiteBands } from '../src/core/frame';
import { PALETTE, PANEL_RGB } from '../src/core/palette';
import { FRAME_BYTES, HEIGHT, WIDTH, crc16, crc32 } from '../src/core/protocol';
import {
  bandIndex,
  bandsFrame,
  checkerFrame,
  checkerIndex,
  fromHex,
  panelImage,
  protocolVectors as v,
  toHexString,
} from './vectors';

const ROW_BYTES = WIDTH / 2;

describe('packIndices / unpackIndices', () => {
  it('match every packing vector', () => {
    for (const vector of v.packing) {
      const packed = packIndices(Uint8Array.from(vector.indices));
      expect(toHexString(packed)).toBe(vector.packed);
      const unpacked = unpackIndices(fromHex(vector.packed));
      const even = vector.indices.length % 2 === 0 ? vector.indices : [...vector.indices, 0];
      expect([...unpacked]).toEqual(even);
    }
  });

  it('put the first pixel in the high nibble', () => {
    expect([...packIndices(Uint8Array.of(15, 0, 0, 15))]).toEqual([0xf0, 0x0f]);
    expect([...unpackIndices(Uint8Array.of(0xab, 0x01))]).toEqual([10, 11, 0, 1]);
    expect(packIndices(new Uint8Array(0))).toHaveLength(0);
    expect(unpackIndices(new Uint8Array(0))).toHaveLength(0);
  });

  it('reject indices above 15', () => {
    expect(() => packIndices(Uint8Array.of(1, 16))).toThrow(RangeError);
    expect(() => packIndices(Uint8Array.of(200))).toThrow(RangeError);
  });

  it('round-trip a whole frame', () => {
    const frame = checkerFrame();
    const indices = unpackIndices(frame);
    expect(indices).toHaveLength(WIDTH * HEIGHT);
    expect(indices[0]).toBe(checkerIndex(0, 0));
    expect(indices[WIDTH * HEIGHT - 1]).toBe(checkerIndex(WIDTH - 1, HEIGHT - 1));
    expect(toHexString(packIndices(indices))).toBe(toHexString(frame));
  });
});

describe('encodeFrame', () => {
  const rgb = (index: number) => PALETTE[index]!.rgb;

  it('encodes the bands picture into the bands vector, with Classic colours and without dithering', () => {
    const picture = panelImage((x) => rgb(bandIndex(x)));
    for (const options of [{ colours: 'classic' as const }, { dither: false }, { dither: true, strength: 0.5, colours: 'classic' as const }]) {
      const frame = encodeFrame(picture, options);
      expect(frame).toHaveLength(FRAME_BYTES);
      expect(toHexString(frame.subarray(0, ROW_BYTES))).toBe(v.frame_bands.first_row_packed);
      expect(crc32(frame).toString(16).padStart(8, '0')).toBe(v.frame_bands.crc32);
      expect(crc16(frame).toString(16).padStart(4, '0')).toBe(v.frame_bands.crc16);
      expect(toHexString(frame)).toBe(toHexString(bandsFrame()));
    }
  });

  it('encodes the checker picture into the checker vector', () => {
    const frame = encodeFrame(panelImage((x, y) => rgb(checkerIndex(x, y))), { colours: 'classic' });
    expect(toHexString(frame.subarray(0, ROW_BYTES))).toBe(v.frame_checker.first_row_packed);
    expect(toHexString(frame.subarray(FRAME_BYTES - ROW_BYTES))).toBe(v.frame_checker.last_row_packed);
    expect(crc32(frame).toString(16).padStart(8, '0')).toBe(v.frame_checker.crc32);
    expect(crc16(frame).toString(16).padStart(4, '0')).toBe(v.frame_checker.crc16);
  });

  it('maps to the exact nearest colour without dithering, also at a decision boundary', () => {
    // Blue (distance 32 260) beats green (32 770); a 6-bit search would pick green.
    const frame = encodeFrame(panelImage(() => [0, 128, 129]), { dither: false });
    expect(frame[0]).toBe(0x33);
    expect(frame.every((byte) => byte === 0x33)).toBe(true);
  });

  it('rejects pictures that are not panel-sized', () => {
    const small = { width: 2, height: 2, data: new Uint8ClampedArray(16) };
    expect(() => encodeFrame(small)).toThrow(RangeError);
    const turned = { width: HEIGHT, height: WIDTH, data: new Uint8ClampedArray(WIDTH * HEIGHT * 4) };
    expect(() => encodeFrame(turned)).toThrow(RangeError);
  });
});

describe('previewFrame', () => {
  it('renders each pixel in its panel colour, opaque', () => {
    const preview = previewFrame(checkerFrame());
    expect(preview.width).toBe(WIDTH);
    expect(preview.height).toBe(HEIGHT);
    expect(preview.data).toHaveLength(WIDTH * HEIGHT * 4);
    for (const [x, y] of [[0, 0], [1, 0], [114, 0], [115, 0], [799, 0], [0, 68], [0, 69], [799, 479], [400, 240]] as const) {
      const o = (y * WIDTH + x) * 4;
      expect([...preview.data.subarray(o, o + 4)]).toEqual([...PANEL_RGB[checkerIndex(x, y)]!, 255]);
    }
    for (let o = 3; o < preview.data.length; o += 4) if (preview.data[o] !== 255) expect.fail(`alpha at ${o}`);
  });

  it('renders nibbles without a palette colour in the black of the panel', () => {
    const frame = new Uint8Array(FRAME_BYTES).fill(0x16);
    frame[1] = 0xf7;
    const data = previewFrame(frame).data;
    expect([...data.subarray(0, 8)]).toEqual([255, 255, 255, 255, 236, 126, 103, 255]);
    expect([...data.subarray(8, 16)]).toEqual([76, 63, 89, 255, 76, 63, 89, 255]);
  });

  it('shows the panel colour of each ideal colour a picture is mapped onto', () => {
    const index = (x: number, y: number) => (x * 7 + y * 3) % 7;
    const data = previewFrame(encodeFrame(panelImage((x, y) => rgb(index(x, y))), { dither: false })).data;
    const panel = panelImage((x, y) => PANEL_RGB[index(x, y)]!).data;
    // Compared as one string: a failing toEqual on 1.5 million numbers takes minutes to print.
    expect(toHexString(new Uint8Array(data.buffer))).toBe(toHexString(new Uint8Array(panel.buffer)));
  });

  it('rejects frames of the wrong size', () => {
    expect(() => previewFrame(new Uint8Array(FRAME_BYTES - 1))).toThrow(RangeError);
    expect(() => previewFrame(new Uint8Array(0))).toThrow(RangeError);
  });

  function rgb(index: number) {
    return PALETTE[index]!.rgb;
  }
});

describe('whiteBands', () => {
  const white = () => new Uint8Array(FRAME_BYTES).fill(0x11);

  it('marks each band of 60 rows that is all white, top first', () => {
    expect(whiteBands(white())).toBe('WWWWWWWW');
    expect(whiteBands(new Uint8Array(FRAME_BYTES))).toBe('........');
    // The picture the device showed: white down to row 354, the photo below.
    const bottomOnly = white();
    bottomOnly.fill(0x23, 355 * ROW_BYTES);
    expect(whiteBands(bottomOnly)).toBe('WWWWW...');
  });

  it('counts one other pixel as not white', () => {
    const frame = white();
    frame[60 * ROW_BYTES + 3] = 0x10;
    expect(whiteBands(frame)).toBe('W.WWWWWW');
  });
});
