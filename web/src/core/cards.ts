/**
 * Cards (牌卡): a background (a photo with a crop, or one of the 7 panel
 * colours) and up to 8 short text boxes. The format is the one in
 * shared/CARDS.md, the same JSON in every app; a card object here is that
 * JSON as it is read (defaults filled in) and written.
 */

import { type Crop } from './crop';
import { PALETTE } from './palette';
import type { ColourName } from './palette';

export const CARD_VERSION = 1;
export const MAX_TEXTS = 8; // text boxes per card
export const MAX_TEXT = 80; // characters per box, after normalizeText()
export const MIN_SIZE = 12; // font size in panel pixels
export const MAX_SIZE = 240;
export const INKS: readonly ColourName[] = PALETTE.map((c) => c.name);
export const ALIGNS = ['left', 'center', 'right'] as const;
export type Align = (typeof ALIGNS)[number];

export interface TextBox {
  /** Normalised: NFC, "\n" line breaks, no outer whitespace. */
  text: string;
  /** x, y, width, height as fractions of the 800 x 480 screen. */
  box: [number, number, number, number];
  /** Font size in panel pixels (bold only). */
  size: number;
  color: ColourName;
  outline: boolean;
  outline_color: ColourName;
  align: Align;
}

export type Background = { color: ColourName } | { image: string; crop: Crop | null };

export interface Card {
  version: 1;
  /** 8 lower-case hex characters. */
  id: string;
  background: Background;
  texts: TextBox[];
}

/** The card breaks the rules of shared/CARDS.md. */
export class CardError extends Error {
  override name = 'CardError';
}

const ID = /^[0-9a-f]{8}$/;
const FILE = /^[0-9A-Za-z_-]{1,40}\.(jpg|jpeg|png)$/;
const EPS = 1e-9;

/** NFC, "\n" line breaks, stripped: what is stored, and what MAX_TEXT counts. */
export function normalizeText(text: string): string {
  return text.normalize('NFC').replace(/\r\n?/g, '\n').trim();
}

/** The number of characters (code points, as the other apps count them) in `text`. */
export function textLength(text: string): number {
  return Array.from(text).length;
}

// Emoji and other characters no panel font draws: pictographs with the emoji selector, the emoji
// planes, emoji-by-default symbols, skin tones, flags, invisible format characters (joiners, selectors).
const UNDRAWABLE =
  /\p{Extended_Pictographic}️|[\u{1F000}-\u{1FFFF}]|\p{Emoji_Presentation}|\p{Emoji_Modifier}|\p{Regional_Indicator}|\p{Cf}|[︀-️]|⃣|[\u{E0000}-\u{E01EF}]/gu;

/** Text as a card can draw it: composed, emoji dropped, line breaks and tabs as spaces, runs of spaces folded. */
export function cleanText(text: string): string {
  return text
    .normalize('NFC')
    .replace(/[\s\p{Cc}]/gu, ' ')
    .replace(UNDRAWABLE, '')
    .split(' ')
    .filter(Boolean)
    .join(' ');
}

/** A new card id that is not in `taken`. */
export function newCardId(taken: ReadonlySet<string> = new Set()): string {
  for (;;) {
    const bytes = crypto.getRandomValues(new Uint8Array(4));
    const id = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
    if (!taken.has(id)) return id;
  }
}

function fail(message: string): never {
  throw new CardError(message);
}

function numbers(value: unknown, n: number, what: string): number[] {
  if (!Array.isArray(value) || value.length !== n || !value.every((v) => typeof v === 'number' && Number.isFinite(v))) {
    fail(`${what} needs ${n} numbers, got ${JSON.stringify(value)}`);
  }
  return value as number[];
}

function inside(box: number[], what: string): void {
  const [x, y, w, h] = box as [number, number, number, number];
  if (x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > 1 + EPS || y + h > 1 + EPS) {
    fail(`${what} must lie inside the screen (fractions 0-1), got ${JSON.stringify(box)}`);
  }
}

function ink(value: unknown, what: string): ColourName {
  if (!INKS.includes(value as ColourName)) fail(`${what} must be one of ${INKS.join(', ')}, got ${JSON.stringify(value)}`);
  return value as ColourName;
}

function record(value: unknown, what: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) fail(`${what} must be an object`);
  return value as Record<string, unknown>;
}

function parseText(value: unknown): TextBox {
  const t = record(value, 'a text box');
  if (typeof t.text !== 'string') fail('the text must be a string');
  const text = normalizeText(t.text);
  if (!text) fail('a text box is empty');
  if (textLength(text) > MAX_TEXT) fail(`a text box has at most ${MAX_TEXT} characters (this one has ${textLength(text)})`);
  const box = numbers(t.box, 4, 'the box');
  inside(box, 'the box');
  const size = t.size ?? 48;
  if (typeof size !== 'number' || !Number.isInteger(size) || size < MIN_SIZE || size > MAX_SIZE) {
    fail(`the font size is a whole number from ${MIN_SIZE} to ${MAX_SIZE}, got ${JSON.stringify(size)}`);
  }
  const outline = t.outline ?? false;
  if (typeof outline !== 'boolean') fail('outline must be true or false');
  const align = t.align ?? 'center';
  if (!ALIGNS.includes(align as Align)) fail(`align must be one of ${ALIGNS.join(', ')}, got ${JSON.stringify(align)}`);
  return {
    text,
    box: box as TextBox['box'],
    size,
    color: ink(t.color ?? 'black', 'the colour'),
    outline,
    outline_color: ink(t.outline_color ?? 'white', 'the outline colour'),
    align: align as Align,
  };
}

function parseBackground(value: unknown): Background {
  const b = record(value, 'the background');
  if (b.image === undefined || b.image === null) return { color: ink(b.color ?? 'white', 'the background colour') };
  if (typeof b.image !== 'string' || !FILE.test(b.image)) {
    fail(`the background image is a plain file name (jpg or png), got ${JSON.stringify(b.image)}`);
  }
  if (b.crop === undefined || b.crop === null) return { image: b.image, crop: null };
  const crop = numbers(b.crop, 4, 'the crop');
  inside(crop, 'the crop');
  return { image: b.image, crop: crop as unknown as Crop };
}

/**
 * A card from its JSON, checked and with the defaults filled in; a CardError if it breaks the rules
 * (it is refused, never repaired).
 */
export function parseCard(json: unknown): Card {
  const c = record(json, 'a card');
  if (c.version !== CARD_VERSION) fail(`unknown card version ${JSON.stringify(c.version)}`);
  if (typeof c.id !== 'string' || !ID.test(c.id)) fail(`card ids are 8 hex characters, got ${JSON.stringify(c.id)}`);
  if (!Array.isArray(c.texts)) fail('a card has a list of texts');
  if (c.texts.length > MAX_TEXTS) fail(`a card has at most ${MAX_TEXTS} text boxes (this one has ${c.texts.length})`);
  return { version: CARD_VERSION, id: c.id, background: parseBackground(c.background), texts: c.texts.map(parseText) };
}
