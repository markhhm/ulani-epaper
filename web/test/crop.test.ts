import { describe, expect, it } from 'vitest';
import { checkCrop, cropBox, defaultCrop, maxZoom, moveCrop, zoomCrop, type Crop } from '../src/core/crop';
import { vectorFile } from './vectors';

interface CropVectors {
  crops: { photo: [number, number]; name: string; crop: Crop; box: number[] }[];
  boxes: { size: [number, number]; crop: Crop; box: number[] }[];
  invalid: { photo: [number, number]; crop: Crop; name: string; reason: string }[];
}
const vectors = vectorFile<CropVectors>('crop-vectors.json');

describe('crop box (shared/vectors/crop-vectors.json)', () => {
  it.each(vectors.crops)('$photo $name', ({ photo, crop, box }) => {
    expect(cropBox(crop, photo[0], photo[1])).toEqual(box);
  });

  it('rounds halves up', () => {
    for (const { size, crop, box } of vectors.boxes) expect(cropBox(crop, size[0], size[1])).toEqual(box);
  });

  it('builds the default crop the vectors list', () => {
    for (const { photo, crop } of vectors.crops.filter((v) => v.name === 'default')) {
      defaultCrop(photo[0], photo[1]).forEach((value, i) => expect(value).toBeCloseTo(crop[i] as number, 12));
    }
  });

  it('accepts every valid vector crop', () => {
    for (const { photo, crop } of vectors.crops) expect(() => checkCrop(crop, photo[0], photo[1])).not.toThrow();
  });

  it('refuses every invalid vector crop', () => {
    for (const { photo, crop, name } of vectors.invalid) expect(() => checkCrop(crop, photo[0], photo[1]), name).toThrow(RangeError);
  });
});

describe('moving and zooming', () => {
  const W = 4000;
  const H = 3000;

  it('zoom 2 keeps the shape and the centre', () => {
    const start = defaultCrop(W, H);
    const zoomed = zoomCrop(start, W, H, 2);
    expect(zoomed[2]).toBeCloseTo(start[2] / 2, 12);
    expect(zoomed[0] + zoomed[2] / 2).toBeCloseTo(start[0] + start[2] / 2, 12);
    expect(zoomed[1] + zoomed[3] / 2).toBeCloseTo(start[1] + start[3] / 2, 12);
    expect(() => checkCrop(zoomed, W, H)).not.toThrow();
  });

  it('zooms around the pinch point', () => {
    const zoomed = zoomCrop(defaultCrop(W, H), W, H, 2, [0.25, 0.2]);
    // The photo point under the pinch stays where it was inside the frame.
    const start = defaultCrop(W, H);
    expect((0.25 - zoomed[0]) / zoomed[2]).toBeCloseTo((0.25 - start[0]) / start[2], 9);
  });

  it('stops at 8x and at 100 photo pixels, and never zooms out past the default', () => {
    const start = defaultCrop(W, H);
    expect(zoomCrop(start, W, H, 1000)[2]).toBeCloseTo(start[2] / 8, 12);
    zoomCrop(start, W, H, 0.001).forEach((value, i) => expect(value).toBeCloseTo(start[i] as number, 12));
    const small = defaultCrop(150, 90); // 90 px high: no zoom allowed
    zoomCrop(small, 150, 90, 4).forEach((value, i) => expect(value).toBeCloseTo(small[i] as number, 12));
    const tall = zoomCrop(defaultCrop(300, 200), 300, 200, 1000); // default is 180 px high: floor is 100 px
    expect(tall[3] * 200).toBeCloseTo(100, 6);
  });

  it('moves inside the photo only', () => {
    const zoomed = zoomCrop(defaultCrop(W, H), W, H, 4);
    const moved = moveCrop(zoomed, W, H, 0.1, -0.05);
    expect(moved[0]).toBeCloseTo(zoomed[0] + 0.1, 12);
    expect(moved[1]).toBeCloseTo(zoomed[1] - 0.05, 12);
    const corner = moveCrop(zoomed, W, H, 5, 5);
    expect(corner[0] + corner[2]).toBeCloseTo(1, 12);
    expect(corner[1] + corner[3]).toBeCloseTo(1, 12);
    expect(moveCrop(zoomed, W, H, -5, -5).slice(0, 2)).toEqual([0, 0]);
  });
});

describe('how far a photo zooms', () => {
  it('is 8x for a big photo and less, or none, where 100 photo pixels or the photo size get in the way', () => {
    expect(maxZoom(4000, 3000)).toBeCloseTo(8, 12);
    expect(maxZoom(300, 200)).toBeCloseTo(1.8, 12); // the default crop is 180 px high, the floor 100 px
    expect(maxZoom(150, 90)).toBeCloseTo(1, 9); // 90 px high: no zoom
  });
});
