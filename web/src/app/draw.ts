/**
 * Drawing for the screen (browser only): a card's photo cut and dithered to the panel's seven colours,
 * a card as a frame, and frames as pictures on a canvas.
 */

import { type Card } from '../core/cards';
import { renderCardIndices } from '../core/cardRender';
import type { Crop } from '../core/crop';
import { toIndices } from '../core/dither';
import type { FitMode } from '../core/fit';
import { packIndices } from '../core/frame';
import { previewImage } from '../core/preview';
import { HEIGHT, WIDTH } from '../core/protocol';
import type { Dithering } from '../core/settings';
import { textRasterizer } from './canvasText';
import { type LoadedPhoto, loadStored, photoToScreen } from './photoLoad';

/** The photo cut to `crop` from the full image, resized to the screen and dithered with `dithering` (its colours and grain). */
export function ditherPhoto(photo: LoadedPhoto, crop: Crop | null, dithering: Dithering, mode: FitMode = 'cover'): Uint8Array {
  return toIndices(photoToScreen(photo, crop, mode), { colours: dithering.colours, strength: dithering.grain });
}

/** `card` drawn over a background already dithered (or null for its plain colour), as palette indices. */
export function drawIndices(card: Card, background: Uint8Array | null): Uint8Array {
  return renderCardIndices(card, background, textRasterizer());
}

/** A stored photo (JPEG, already upright and capped) cut to `crop` (or whole, with `mode` contain) and dithered with `dithering`: a background ready to draw on. */
export async function ditherStored(stored: Uint8Array, crop: Crop | null, dithering: Dithering, mode: FitMode = 'cover'): Promise<Uint8Array> {
  const loaded = await loadStored(stored);
  try {
    return ditherPhoto(loaded, crop, dithering, mode);
  } finally {
    loaded.bitmap.close();
  }
}

/** A card as the frame to upload: its stored photo (if any) cut, dithered, and the text drawn crisp on it. */
export async function drawCard(card: Card, dithering: Dithering, background: Uint8Array | undefined): Promise<Uint8Array> {
  let photo: Uint8Array | null = null;
  if ('image' in card.background) {
    if (!background) throw new Error(`the photo of card ${card.id} is missing`);
    photo = await ditherStored(background, card.background.crop, dithering);
  }
  return packIndices(drawIndices(card, photo));
}

/** The size `canvas` covers on screen in device pixels; its own size while it is not laid out. */
export function screenPixels(canvas: HTMLCanvasElement): { width: number; height: number } {
  const box = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  const width = Math.round(box.width * ratio);
  const height = Math.round(box.height * ratio);
  return width > 0 && height > 0 ? { width, height } : { width: canvas.width, height: canvas.height };
}

/**
 * Draw 800 x 480 palette indices onto `canvas` as the panel shows them (core/preview.ts), as many pixels
 * as the canvas covers on screen, so the browser does not scale the picture again.
 */
export function paint(canvas: HTMLCanvasElement, indices: Uint8Array): void {
  const target = canvas.getContext('2d');
  if (!target) return;
  const { width, height } = screenPixels(canvas);
  if (canvas.width !== width) canvas.width = width;
  if (canvas.height !== height) canvas.height = height;
  const picture = previewImage({ width: WIDTH, height: HEIGHT, indices }, width, height);
  target.putImageData(new ImageData(picture.data as Uint8ClampedArray<ArrayBuffer>, width, height), 0, 0);
}
