import { describe, expect, it } from 'vitest';
import { type Background, MAX_TEXTS, type TextBox } from '../src/core/cards';
import { addText, moveText, newText, refit, scaleText } from '../src/core/cardEdit';
import type { Measure } from '../src/core/cardLayout';

/** Every character is as wide as the font size; 國 reaches 0.9 size above the baseline and 0.1 below. */
const square: Measure = {
  width: (text, size) => Array.from(text).length * size,
  extent: (size) => ({ above: Math.round(size * 0.9), below: Math.round(size * 0.1) }),
};

const text = (extra: Partial<TextBox> = {}): TextBox => ({
  text: 'abcd',
  box: [0.2, 0.3, 0.5, 0.2],
  size: 40,
  color: 'black',
  outline: false,
  outline_color: 'white',
  align: 'center',
  ...extra,
});

describe('moving a text', () => {
  it('moves the box by a fraction of the screen and keeps it on the screen', () => {
    const moved = moveText(text(), 0.1, -0.05).box;
    expect(moved[0]).toBeCloseTo(0.3, 12);
    expect(moved[1]).toBeCloseTo(0.25, 12);
    expect(moved.slice(2)).toEqual([0.5, 0.2]);
    expect(moveText(text(), 5, 5).box).toEqual([0.5, 0.8, 0.5, 0.2]);
    expect(moveText(text(), -5, -5).box.slice(0, 2)).toEqual([0, 0]);
  });
});

describe('making a box as tall as its text', () => {
  it('grows with the lines and with the outline, and moves up rather than off the screen', () => {
    // 'abcd' at size 40 is 160 px: one line in a 0.5 (400 px) wide box, two lines when it is 0.1 (80 px) wide
    const one = refit(text({ box: [0.2, 0.3, 0.5, 0.9] }), square);
    const two = refit(text({ box: [0.2, 0.3, 0.1, 0.9] }), square);
    expect(two.box[3]).toBeGreaterThan(one.box[3]);
    const outlined = refit(text({ outline: true }), square);
    expect(outlined.box[3]).toBeGreaterThan(refit(text(), square).box[3]);
    const low = refit(text({ box: [0.2, 0.95, 0.1, 0.05], text: 'abcdefgh' }), square);
    expect(low.box[1] + low.box[3]).toBeCloseTo(1, 12);
    expect(low.box[1]).toBeLessThan(0.95);
  });

  it('keeps the text it was given and shows all of it', () => {
    const refitted = refit(text({ box: [0.1, 0.1, 0.12, 0.01], text: 'abcdefghij' }), square);
    expect(refitted.text).toBe('abcdefghij');
    expect(refitted.box[3]).toBeGreaterThan(0.1);
  });
});

describe('resizing a text with a pinch', () => {
  it('scales the font size and the width together around the middle of the box', () => {
    const big = scaleText(text(), 1.5, square);
    expect(big.size).toBe(60);
    expect(big.box[2]).toBeCloseTo(0.75, 12);
    expect(big.box[0] + big.box[2] / 2).toBeCloseTo(0.2 + 0.25, 12); // same middle
    const small = scaleText(text(), 0.5, square);
    expect(small.size).toBe(20);
    expect(small.box[2]).toBeCloseTo(0.25, 12);
  });

  it('stays within 12 to 240 pixels and the width of the screen', () => {
    expect(scaleText(text({ size: 200 }), 3, square).size).toBe(240);
    expect(scaleText(text({ size: 14 }), 0.1, square).size).toBe(12);
    const wide = scaleText(text({ box: [0.1, 0.3, 0.8, 0.2] }), 3, square);
    expect(wide.box[2]).toBe(1);
    expect(wide.box[0]).toBe(0);
  });

  it('never makes the box narrower than one character', () => {
    // 40 px wide at size 100 is less than a character: the box grows to hold one
    const narrow = scaleText(text({ size: 100, box: [0.2, 0.3, 0.05, 0.2] }), 1, square);
    expect(narrow.box[2] * 800).toBeGreaterThanOrEqual(100);
    expect(scaleText(text({ size: 100, box: [0.2, 0.3, 0.3, 0.2] }), 0.3, square).box[2] * 800).toBeGreaterThanOrEqual(30);
  });
});

describe('a new text', () => {
  const photo: Background = { image: 'a1b2c3d4.jpg', crop: null };

  it('is white with a black outline on a photo, plain black or white on a colour', () => {
    expect(newText(photo, square)).toMatchObject({ color: 'white', outline: true, outline_color: 'black' });
    expect(newText({ color: 'yellow' }, square)).toMatchObject({ color: 'black', outline: false });
    expect(newText({ color: 'white' }, square)).toMatchObject({ color: 'black', outline: false });
    expect(newText({ color: 'blue' }, square)).toMatchObject({ color: 'white', outline: false });
    expect(newText({ color: 'black' }, square)).toMatchObject({ color: 'white', outline: false });
  });

  it('sits in the middle of the screen, centred, and fits its box', () => {
    const t = newText({ color: 'white' }, square);
    expect(t.align).toBe('center');
    expect(t.box[0] + t.box[2] / 2).toBeCloseTo(0.5, 12);
    expect(t.box[1] + t.box[3] / 2).toBeCloseTo(0.5, 2);
  });

  it('is added at most 8 times, each a little lower so they do not hide each other', () => {
    let texts: TextBox[] = [];
    for (let i = 0; i < MAX_TEXTS + 2; i++) texts = addText(texts, { color: 'white' }, square);
    expect(texts).toHaveLength(MAX_TEXTS);
    expect(texts[1]?.box[1]).toBeGreaterThan(texts[0]?.box[1] as number);
  });
});
