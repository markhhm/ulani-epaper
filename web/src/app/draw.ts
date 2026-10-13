/**
 * Drawing for the screen (browser only): a card's photo cut and dithered to the panel's seven colours,
 * a card as a frame, and frames as pictures on a canvas.
 */

import { type Card } from '../core/cards';
import { renderCardIndices } from '../core/cardRender';
import type { Crop } from '../core/crop';
import { toIndices } from '../core/dither';
import type { FitMode } from '../core/fit';
import { packIndices, previewFrame, type RgbaImage } from '../core/frame';
import { HEIGHT, WIDTH } from '../core/protocol';
import { textRasterizer } from './canvasText';
import { type LoadedPhoto, loadStored, makeCanvas, photoToScreen } from './photoLoad';

/** The photo cut to `crop` from the full image, resized to the screen and dithered at strength `grain`. */
export function ditherPhoto(photo: LoadedPhoto, crop: Crop | null, grain: number, mode: FitMode = 'cover'): Uint8Array {
  return toIndices(photoToScreen(photo, crop, mode), { strength: grain });
}

/** `card` drawn over a background already dithered (or null for its plain colour), as palette indices. */
export function drawIndices(card: Card, background: Uint8Array | null): Uint8Array {
  return renderCardIndices(card, background, textRasterizer());
}

/** A stored photo (JPEG, already upright and capped) cut to `crop` (or whole, with `mode` contain) and dithered at strength `grain`: a background ready to draw on. */
export async function ditherStored(stored: Uint8Array, crop: Crop | null, grain: number, mode: FitMode = 'cover'): Promise<Uint8Array> {
  const loaded = await loadStored(stored);
  try {
    return ditherPhoto(loaded, crop, grain, mode);
  } finally {
    loaded.bitmap.close();
  }
}

/** A card as the frame to upload: its stored photo (if any) cut, dithered, and the text drawn crisp on it. */
export async function drawCard(card: Card, grain: number, background: Uint8Array | undefined): Promise<Uint8Array> {
  let photo: Uint8Array | null = null;
  if ('image' in card.background) {
    if (!background) throw new Error(`the photo of card ${card.id} is missing`);
    photo = await ditherStored(background, card.background.crop, grain);
  }
  return packIndices(drawIndices(card, photo));
}

/** Palette indices as the panel shows them (7 colours), ready for putImageData. */
export function indicesPicture(indices: Uint8Array): RgbaImage {
  return previewFrame(packIndices(indices));
}

/** Draw `picture` (800 x 480) onto `canvas`, scaled to the canvas's own size. */
export function paint(canvas: HTMLCanvasElement, picture: RgbaImage): void {
  const target = canvas.getContext('2d');
  if (!target) return;
  if (canvas.width === WIDTH && canvas.height === HEIGHT) {
    target.putImageData(new ImageData(picture.data as Uint8ClampedArray<ArrayBuffer>, WIDTH, HEIGHT), 0, 0);
    return;
  }
  const { canvas: full, context } = makeCanvas(WIDTH, HEIGHT);
  context.putImageData(new ImageData(picture.data as Uint8ClampedArray<ArrayBuffer>, WIDTH, HEIGHT), 0, 0);
  target.imageSmoothingEnabled = true;
  target.imageSmoothingQuality = 'high';
  target.drawImage(full as CanvasImageSource, 0, 0, canvas.width, canvas.height);
}

/** A frame (as uploaded) as a picture. */
export function framePicture(frame: Uint8Array): RgbaImage {
  return previewFrame(frame);
}
