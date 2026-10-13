/**
 * Opening a photo (browser only): the one load step every photo goes through (shared/CROP.md,
 * "Photo size"). A photo over 50 megapixels is refused from its file header, before a pixel is
 * decoded; the rest is decoded upright and shrunk to the 4K cap with the exact size from
 * core/photo.ts. Everything after this (crops, cards, dithering) uses this full capped image, never
 * a smaller preview.
 */

import type { Crop } from '../core/crop';
import { type FitMode, fitToPanel, orientedBitmap } from '../core/fit';
import type { RgbaImage } from '../core/frame';
import { capSize, isOverLimit, PhotoTooLarge, PhotoUnreadable, photoSizeFromHeader } from '../core/photo';
import { DeviceError } from '../core/protocol';
import type { PreparedPhoto } from '../core/library';

/** A decoded photo: upright, at most 4K. */
export interface LoadedPhoto {
  readonly bitmap: ImageBitmap;
  readonly width: number;
  readonly height: number;
}

/** How much of a file to look at for its size: JPEG headers can hold sizeable EXIF and colour profile blocks. */
const HEADER_BYTES = 512 * 1024;
export const JPEG_QUALITY = 0.92;

type Canvas = OffscreenCanvas | HTMLCanvasElement;
type Context = OffscreenCanvasRenderingContext2D | CanvasRenderingContext2D;

/** A canvas and its 2D context. */
export function makeCanvas(width: number, height: number, opaque = true): { canvas: Canvas; context: Context } {
  let canvas: Canvas;
  if (typeof OffscreenCanvas !== 'undefined') {
    canvas = new OffscreenCanvas(width, height);
  } else {
    canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
  }
  const context = canvas.getContext('2d', { alpha: !opaque, willReadFrequently: true }) as Context | null;
  if (!context) throw new DeviceError('This browser cannot draw pictures (no 2D canvas).');
  return { canvas, context };
}

/**
 * Open a photo file. Throws PhotoTooLarge for a photo over 50 megapixels (the user shrinks it and
 * chooses it again) and a PhotoUnreadable for a file the browser cannot open.
 */
export async function loadPhoto(file: Blob): Promise<LoadedPhoto> {
  const header = photoSizeFromHeader(new Uint8Array(await file.slice(0, HEADER_BYTES).arrayBuffer()));
  if (header && isOverLimit(header.width, header.height)) throw new PhotoTooLarge();
  let bitmap: ImageBitmap;
  try {
    bitmap = await orientedBitmap(file);
  } catch (cause) {
    throw new PhotoUnreadable({ cause });
  }
  if (isOverLimit(bitmap.width, bitmap.height)) {
    bitmap.close(); // a format whose header we cannot read: the size is known only now
    throw new PhotoTooLarge();
  }
  const cap = capSize(bitmap.width, bitmap.height);
  if (cap.width === bitmap.width && cap.height === bitmap.height) return { bitmap, width: cap.width, height: cap.height };
  const { canvas, context } = makeCanvas(cap.width, cap.height);
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = 'high';
  context.drawImage(bitmap, 0, 0, cap.width, cap.height);
  bitmap.close();
  return { bitmap: await createImageBitmap(canvas), width: cap.width, height: cap.height };
}

async function toJpeg(canvas: Canvas): Promise<Uint8Array> {
  const blob =
    canvas instanceof HTMLCanvasElement
      ? await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, 'image/jpeg', JPEG_QUALITY))
      : await (canvas as OffscreenCanvas).convertToBlob({ type: 'image/jpeg', quality: JPEG_QUALITY });
  if (!blob) throw new DeviceError('This browser cannot save the photo.');
  return new Uint8Array(await blob.arrayBuffer());
}

/** The photo as it is stored with a card: JPEG (quality 92) at its capped size. */
export async function encodePhoto(photo: LoadedPhoto): Promise<PreparedPhoto> {
  const { canvas, context } = makeCanvas(photo.width, photo.height);
  context.fillStyle = '#ffffff'; // transparent PNGs print as white
  context.fillRect(0, 0, photo.width, photo.height);
  context.drawImage(photo.bitmap, 0, 0);
  return { jpeg: await toJpeg(canvas), width: photo.width, height: photo.height };
}

/** Any photo file (a stored background, one from a card file) through the photo rules, as stored. */
export async function preparePhotoBytes(bytes: Uint8Array): Promise<PreparedPhoto> {
  const photo = await loadPhoto(new Blob([bytes as BlobPart]));
  try {
    return await encodePhoto(photo);
  } finally {
    photo.bitmap.close();
  }
}

/** A photo as it was stored: already upright and capped, so only decoded. */
export async function loadStored(bytes: Uint8Array): Promise<LoadedPhoto> {
  const bitmap = await createImageBitmap(new Blob([bytes as BlobPart]));
  return { bitmap, width: bitmap.width, height: bitmap.height };
}

/** The photo cut to `crop` (null: the centre) from the full image and resized to the 800 x 480 screen. */
export function photoToScreen(photo: LoadedPhoto, crop: Crop | null, mode: FitMode = 'cover'): RgbaImage {
  return fitToPanel(photo.bitmap, mode, undefined, crop);
}
