/**
 * The edits the card editor makes to text boxes, as pure functions: moving, resizing with a pinch,
 * keeping a box as tall as its text, and a new text with ink that suits the background. Boxes are
 * fractions of the 800 x 480 screen (shared/CARDS.md).
 */

import { type Background, MAX_SIZE, MAX_TEXTS, MIN_SIZE, type TextBox } from './cards';
import { fitBoxHeight, type Measure, outlineRadius } from './cardLayout';
import type { ColourName } from './palette';
import { WIDTH } from './protocol';

const clamp = (value: number, low: number, high: number) => Math.min(Math.max(value, low), high);

/** The narrowest box that still holds one wide character at the text's size, as a fraction of the screen. */
function minWidth(t: Pick<TextBox, 'size' | 'outline'>): number {
  const outline = t.outline ? outlineRadius(t.size) : 0;
  return Math.min(1, (t.size + 2 * outline + 2) / WIDTH);
}

/**
 * `t` with a box that is as tall as its text and on the screen: the width stays (at least one
 * character wide), the height follows the lines, and a box that would run off the bottom moves up.
 */
export function refit(t: TextBox, measure: Measure): TextBox {
  const [x, y, w] = t.box;
  const width = clamp(w, minWidth(t), 1);
  const height = fitBoxHeight(t, width, 0, measure);
  return { ...t, box: [clamp(x, 0, 1 - width), clamp(y, 0, 1 - height), width, height] };
}

/** `t` moved by a fraction of the screen, never off it. */
export function moveText(t: TextBox, dx: number, dy: number): TextBox {
  const [x, y, w, h] = t.box;
  return { ...t, box: [clamp(x + dx, 0, 1 - w), clamp(y + dy, 0, 1 - h), w, h] };
}

/** `t` resized by a pinch: the font size and the width scale together around the middle of the box. */
export function scaleText(t: TextBox, scale: number, measure: Measure): TextBox {
  const size = clamp(Math.round(t.size * scale), MIN_SIZE, MAX_SIZE);
  const ratio = size / t.size;
  const [x, , w] = t.box;
  const width = Math.min(1, w * ratio);
  const centre = x + w / 2;
  return refit({ ...t, size, box: [centre - width / 2, t.box[1], width, t.box[3]] }, measure);
}

const DARK: readonly ColourName[] = ['black', 'blue', 'red', 'green'];

/** A new, empty text with ink that reads on `background`: white with a black outline on a photo. */
export function newText(background: Background, measure: Measure): TextBox {
  const photo = 'image' in background;
  const dark = !photo && DARK.includes(background.color);
  const white = photo || dark;
  const fresh = refit(
    {
      text: '',
      box: [0.1, 0.4, 0.8, 0.2],
      size: 56,
      color: white ? 'white' : 'black',
      outline: photo,
      outline_color: white ? 'black' : 'white',
      align: 'center',
    },
    measure,
  );
  return { ...fresh, box: [fresh.box[0], 0.5 - fresh.box[3] / 2, fresh.box[2], fresh.box[3]] };
}

/**
 * `texts` plus a new empty one (none when the card has 8 already): the first in the middle of the
 * screen, later ones just below the one before, or above it when there is no room below.
 */
export function addText(texts: readonly TextBox[], background: Background, measure: Measure): TextBox[] {
  if (texts.length >= MAX_TEXTS) return [...texts];
  const fresh = newText(background, measure);
  const height = fresh.box[3];
  const last = texts[texts.length - 1];
  let y = 0.5 - height / 2;
  if (last) {
    const below = last.box[1] + last.box[3] + 0.03;
    y = below + height <= 1 ? below : Math.max(0, last.box[1] - height - 0.03);
  }
  return [...texts, { ...fresh, box: [fresh.box[0], y, fresh.box[2], height] }];
}
