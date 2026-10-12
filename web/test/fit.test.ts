import { afterEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_FIT, decodePicture, fitPlacement, fitToPanel, flattenOnWhite } from '../src/core/fit';
import { DeviceError, HEIGHT, WIDTH } from '../src/core/protocol';
import { fitVectors as fv } from './vectors';

describe('fitPlacement', () => {
  it('matches every placement vector', () => {
    expect(fv.version).toBe(1);
    expect(fv.panel).toEqual([WIDTH, HEIGHT]);
    for (const vector of fv.placements) {
      const [w, h] = vector.size;
      const { source, target } = fitPlacement(w, h, vector.mode);
      const label = `${w}x${h} ${vector.mode}`;
      // The vectors give the source as a box; compare it the way it was built.
      expect([source.x, source.y, source.x + source.width, source.y + source.height], label).toEqual(vector.source);
      expect([target.x, target.y, target.width, target.height], label).toEqual(vector.target);
    }
  });

  it('covers the panel with a centred crop of the panel shape', () => {
    expect(fitPlacement(4000, 3000, 'cover')).toEqual({
      source: { x: 0, y: 300, width: 4000, height: 2400 },
      target: { x: 0, y: 0, width: 800, height: 480 },
    });
    expect(fitPlacement(1080, 1920, 'cover')).toEqual({
      source: { x: 0, y: 636, width: 1080, height: 648 },
      target: { x: 0, y: 0, width: 800, height: 480 },
    });
    expect(fitPlacement(2000, 600, 'cover').source).toEqual({ x: 500, y: 0, width: 1000, height: 600 });
  });

  it('contains the whole picture, centred on white', () => {
    expect(fitPlacement(4000, 3000, 'contain')).toEqual({
      source: { x: 0, y: 0, width: 4000, height: 3000 },
      target: { x: 80, y: 0, width: 640, height: 480 },
    });
    expect(fitPlacement(1920, 1080, 'contain').target).toEqual({ x: 0, y: 15, width: 800, height: 450 });
    // Scaled up, too.
    expect(fitPlacement(100, 100, 'contain').target).toEqual({ x: 160, y: 0, width: 480, height: 480 });
  });

  it('rounds the contained size half to even and keeps at least one pixel', () => {
    expect(fitPlacement(5, 960, 'contain').target).toEqual({ x: 399, y: 0, width: 2, height: 480 });
    expect(fitPlacement(7, 960, 'contain').target).toEqual({ x: 398, y: 0, width: 4, height: 480 });
    expect(fitPlacement(1, 10000, 'contain').target).toEqual({ x: 399, y: 0, width: 1, height: 480 });
  });

  it('stretches the whole picture onto the whole panel', () => {
    expect(fitPlacement(333, 200, 'stretch')).toEqual({
      source: { x: 0, y: 0, width: 333, height: 200 },
      target: { x: 0, y: 0, width: 800, height: 480 },
    });
  });

  it('fits onto other panel sizes', () => {
    expect(fitPlacement(400, 400, 'contain', { width: 200, height: 100 }).target).toEqual({
      x: 50, y: 0, width: 100, height: 100,
    });
    expect(fitPlacement(400, 400, 'cover', { width: 200, height: 100 }).source).toEqual({
      x: 0, y: 100, width: 400, height: 200,
    });
  });

  it('defaults to cover', () => {
    expect(DEFAULT_FIT).toBe('cover');
  });

  it('rejects sizes that are not positive and unknown modes', () => {
    for (const [w, h] of [[0, 10], [10, 0], [-1, 10], [Number.NaN, 10], [10, Infinity]]) {
      expect(() => fitPlacement(w!, h!, 'cover')).toThrow(RangeError);
    }
    expect(() => fitPlacement(10, 10, 'cover', { width: 0, height: 480 })).toThrow(RangeError);
    expect(() => fitPlacement(10, 10, 'zoom' as never)).toThrow(RangeError);
  });
});

describe('flattenOnWhite', () => {
  it('matches every flatten vector', () => {
    const n = fv.flatten.length;
    const data = new Uint8ClampedArray(n * 4);
    fv.flatten.forEach((vector, i) => data.set(vector.rgba, i * 4));
    const flat = flattenOnWhite({ width: n, height: 1, data });
    expect(flat.width).toBe(n);
    expect(flat.height).toBe(1);
    fv.flatten.forEach((vector, i) => {
      expect([...flat.data.subarray(i * 4, i * 4 + 4)], `rgba ${vector.rgba.join(', ')}`).toEqual([...vector.rgb, 255]);
    });
  });

  it('leaves the input alone', () => {
    const data = Uint8ClampedArray.of(0, 0, 0, 0);
    expect([...flattenOnWhite({ width: 1, height: 1, data }).data]).toEqual([255, 255, 255, 255]);
    expect([...data]).toEqual([0, 0, 0, 0]);
  });

  it('rejects data that does not match the size', () => {
    expect(() => flattenOnWhite({ width: 2, height: 1, data: new Uint8ClampedArray(4) })).toThrow(RangeError);
  });
});

/** Stand-in for the browser's 2D canvas: records what is drawn. */
class FakeContext {
  static last: FakeContext | undefined;
  readonly calls: unknown[][] = [];
  fillStyle = '';
  imageSmoothingEnabled = false;
  imageSmoothingQuality = 'low';

  constructor(
    readonly width: number,
    readonly height: number,
    readonly settings: unknown,
  ) {
    FakeContext.last = this;
  }

  fillRect(...args: number[]) {
    this.calls.push(['fillRect', this.fillStyle, ...args]);
  }

  drawImage(...args: unknown[]) {
    this.calls.push(['drawImage', this.imageSmoothingEnabled, this.imageSmoothingQuality, ...args]);
  }

  getImageData(x: number, y: number, width: number, height: number) {
    this.calls.push(['getImageData', x, y, width, height]);
    return { width, height, data: new Uint8ClampedArray(width * height * 4).fill(255) };
  }
}

class FakeOffscreenCanvas {
  constructor(
    readonly width: number,
    readonly height: number,
  ) {}

  getContext(kind: string, settings: unknown) {
    return kind === '2d' ? new FakeContext(this.width, this.height, settings) : null;
  }
}

describe('fitToPanel (with a stand-in canvas)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('draws the placement onto white with high-quality smoothing', () => {
    vi.stubGlobal('OffscreenCanvas', FakeOffscreenCanvas);
    const picture = { width: 4000, height: 3000 } as ImageBitmap;
    const out = fitToPanel(picture, 'contain');
    const context = FakeContext.last!;
    expect([context.width, context.height]).toEqual([WIDTH, HEIGHT]);
    expect(context.settings).toMatchObject({ willReadFrequently: true });
    expect(context.calls).toEqual([
      ['fillRect', '#ffffff', 0, 0, WIDTH, HEIGHT],
      ['drawImage', true, 'high', picture, 0, 0, 4000, 3000, 80, 0, 640, 480],
      ['getImageData', 0, 0, WIDTH, HEIGHT],
    ]);
    expect([out.width, out.height, out.data.length]).toEqual([WIDTH, HEIGHT, WIDTH * HEIGHT * 4]);
  });

  it('crops for cover by default', () => {
    vi.stubGlobal('OffscreenCanvas', FakeOffscreenCanvas);
    const picture = { width: 1000, height: 1000 } as ImageBitmap;
    fitToPanel(picture);
    expect(FakeContext.last!.calls[1]).toEqual(['drawImage', true, 'high', picture, 0, 200, 1000, 600, 0, 0, WIDTH, HEIGHT]);
  });
});

describe('decodePicture (with a stand-in decoder)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function fakeBitmap(width: number, height: number) {
    return { width, height, close: vi.fn() };
  }

  it('decodes upright and keeps pictures that are small enough', async () => {
    const bitmap = fakeBitmap(1600, 1200);
    const decode = vi.fn(async () => bitmap);
    vi.stubGlobal('createImageBitmap', decode);
    const file = new Blob(['x']);
    expect(await decodePicture(file)).toBe(bitmap);
    expect(decode).toHaveBeenCalledTimes(1);
    expect(decode).toHaveBeenCalledWith(file, { imageOrientation: 'from-image' });
    expect(bitmap.close).not.toHaveBeenCalled();
  });

  it('scales large pictures down to the long-side limit', async () => {
    const big = fakeBitmap(4000, 3000);
    const small = fakeBitmap(1600, 1200);
    const decode = vi.fn(async (source: unknown) => (source === big ? small : big));
    vi.stubGlobal('createImageBitmap', decode);
    expect(await decodePicture(new Blob(['x']))).toBe(small);
    expect(decode).toHaveBeenLastCalledWith(big, { resizeWidth: 1600, resizeHeight: 1200, resizeQuality: 'high' });
    expect(big.close).toHaveBeenCalled();

    decode.mockClear();
    await decodePicture(new Blob(['x']), { maxLongSide: 1000 });
    expect(decode).toHaveBeenLastCalledWith(big, { resizeWidth: 1000, resizeHeight: 750, resizeQuality: 'high' });
  });

  it('retries without the orientation option where it is unknown', async () => {
    const bitmap = fakeBitmap(10, 10);
    const decode = vi.fn(async (_source: unknown, options: ImageBitmapOptions) => {
      if (options.imageOrientation === 'from-image') throw new TypeError('bad enum value');
      return bitmap;
    });
    vi.stubGlobal('createImageBitmap', decode);
    expect(await decodePicture(new Blob(['x']))).toBe(bitmap);
    expect(decode).toHaveBeenCalledTimes(2);
  });

  it('reports files the browser cannot decode as a DeviceError', async () => {
    vi.stubGlobal('createImageBitmap', vi.fn(async () => {
      throw new DOMException('The source image could not be decoded.', 'InvalidStateError');
    }));
    await expect(decodePicture(new Blob(['not a picture']))).rejects.toBeInstanceOf(DeviceError);
  });

  it('rejects a bad long-side limit', async () => {
    await expect(decodePicture(new Blob(['x']), { maxLongSide: 0 })).rejects.toThrow(RangeError);
  });
});
