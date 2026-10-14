import { describe, expect, it } from 'vitest';
import tables from '../../shared/dither/natural-tables.json';
import { COLOURS, PALETTE, PANEL_RGB, nearestIndex, nibbleRgb } from '../src/core/palette';
import { protocolVectors as v } from './vectors';

describe('palette', () => {
  it('lists the seven colours by index and by name', () => {
    expect(PALETTE.map((c) => c.index)).toEqual([0, 1, 2, 3, 4, 5, 6]);
    for (const c of PALETTE) expect(COLOURS[c.name]).toBe(c);
    expect(Object.isFrozen(PALETTE)).toBe(true);
    expect(Object.isFrozen(PALETTE[6]!.rgb)).toBe(true);
  });
});

describe('PANEL_RGB', () => {
  it('holds the datasheet colours of the panel, by index: palette_srgb of the Natural tables', () => {
    expect(PANEL_RGB).toEqual(tables.palette_srgb);
    expect(PANEL_RGB).toEqual([[76, 63, 89], [255, 255, 255], [73, 151, 107], [87, 97, 161], [216, 95, 99], [254, 237, 116], [236, 126, 103]]);
    expect(Object.isFrozen(PANEL_RGB)).toBe(true);
    expect(Object.isFrozen(PANEL_RGB[4])).toBe(true);
  });
});

describe('nearestIndex', () => {
  it('matches the nearest-colour vectors', () => {
    for (const vector of v.nearest_colour) expect(nearestIndex(...vector.rgb)).toBe(vector.index);
  });

  it('maps every palette colour to itself', () => {
    for (const c of PALETTE) expect(nearestIndex(...c.rgb)).toBe(c.index);
  });

  it('uses squared RGB distance', () => {
    // Mid grey is closer to orange (127² + 3² + 128²) than to white (3 · 127²).
    expect(nearestIndex(128, 128, 128)).toBe(COLOURS.orange.index);
    expect(nearestIndex(127, 127, 127)).toBe(COLOURS.orange.index);
    expect(nearestIndex(60, 60, 60)).toBe(COLOURS.black.index);
  });

  it('picks the lowest index on a tie', () => {
    // Equally far from yellow (255, 255, 0) and orange (255, 125, 0).
    expect(nearestIndex(255, 190, 0)).toBe(COLOURS.yellow.index);
    expect(nearestIndex(255, 191, 0)).toBe(COLOURS.yellow.index);
    expect(nearestIndex(255, 189, 0)).toBe(COLOURS.orange.index);
  });

  it('accepts channels outside 0-255', () => {
    expect(nearestIndex(-40, -40, 300)).toBe(COLOURS.blue.index);
    expect(nearestIndex(400, 400, 400)).toBe(COLOURS.white.index);
    expect(nearestIndex(-500, -500, -500)).toBe(COLOURS.black.index);
  });
});

describe('nibbleRgb', () => {
  it('gives the panel colours, and the black of the panel for nibbles without one', () => {
    for (const c of PALETTE) expect(nibbleRgb(c.index)).toEqual(PANEL_RGB[c.index]);
    for (let n = 7; n < 16; n++) expect(nibbleRgb(n)).toEqual([76, 63, 89]);
  });

  it('rejects values that are not nibbles', () => {
    for (const bad of [-1, 16, 255, 1.5, Number.NaN]) expect(() => nibbleRgb(bad)).toThrow(RangeError);
  });
});
