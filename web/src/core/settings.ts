/**
 * What the app remembers besides the cards: the page plan, the colours and grain of the dithering, the
 * photo behind each calendar page and the fingerprint of the frame last sent to each card page. Kept in
 * the browser's IndexedDB and in backups (settings.json).
 */

import type { Crop } from './crop';
import type { ColourMode } from './dither';
import { DEFAULT_PAGES, PAGE_KINDS, type PageKind, type PagePlan } from './pages';
import { USER_SLOTS } from './protocol';

/** The colour choices of every app, in the order they are offered: 自然 / Natural, 經典 / Classic. */
export const COLOUR_MODES: readonly ColourMode[] = Object.freeze(['natural', 'classic'] as const);

/** Grain levels offered in every app: the share of the dithering error that is spread. */
export const GRAIN_LEVELS = Object.freeze([
  { key: 'standard', strength: 1 },
  { key: 'soft', strength: 0.8 },
  { key: 'softer', strength: 0.65 },
  { key: 'smoothest', strength: 0.5 },
] as const);

/** 標準 / Standard. */
const STANDARD_GRAIN = GRAIN_LEVELS[0].strength;

/** How photos are dithered: the colour choice and the grain. */
export interface Dithering {
  colours: ColourMode;
  /** Dithering strength, above 0 and at most 1. */
  grain: number;
}

/** The photo behind a calendar page, or of a photo page: its file in the store (always `page-<page>.jpg`) and the part of it that is shown. */
export interface PageBackground {
  image: string;
  crop: Crop | null;
  /** A photo page shows the whole photo with white edges, the crop unused (kept for when it fills the screen again); absent, the photo fills the screen. */
  fit?: 'contain';
}

/** The store's file name for the photo behind page `slot`. */
export const backgroundFile = (slot: number): string => `page-${slot}.jpg`;

export interface Settings extends Dithering {
  pages: PagePlan;
  /**
   * Page (1-4) -> fingerprint of the card frame this app last put there. Kept while the page is set to
   * another kind, and forgotten once this app sends something else to it.
   */
  lastSent: Record<number, string>;
  /** When the last backup file was made (ISO time), or null. */
  lastBackup: string | null;
  /** Page (1-4) -> the photo its calendar page is drawn on, or that its photo page shows. */
  backgrounds: Record<number, PageBackground>;
}

export function defaultSettings(): Settings {
  return { pages: { ...DEFAULT_PAGES }, colours: 'natural', grain: STANDARD_GRAIN, lastSent: {}, lastBackup: null, backgrounds: {} };
}

function slot(key: string): number {
  const n = Number(key);
  if (!USER_SLOTS.includes(n)) throw new RangeError(`pages are 1-4, got ${JSON.stringify(key)}`);
  return n;
}

/** A crop's four numbers, lying inside the photo; whether it fits the photo is checked where the photo is (core/library.ts). */
function parseBackground(slotNumber: number, value: unknown): PageBackground {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new RangeError(`backgrounds: page ${slotNumber} needs an object`);
  const { image, crop, fit } = value as Record<string, unknown>;
  if (image !== backgroundFile(slotNumber)) throw new RangeError(`backgrounds: the photo of page ${slotNumber} is ${backgroundFile(slotNumber)}, got ${JSON.stringify(image)}`);
  if (fit !== undefined && fit !== 'cover' && fit !== 'contain') throw new RangeError(`backgrounds: page ${slotNumber} fits its photo as cover or contain, got ${JSON.stringify(fit)}`);
  const whole = fit === 'contain' ? { fit: 'contain' as const } : {};
  if (crop === undefined || crop === null) return { image, crop: null, ...whole };
  const ok =
    Array.isArray(crop) &&
    crop.length === 4 &&
    crop.every((v) => typeof v === 'number' && Number.isFinite(v)) &&
    (crop[0] as number) >= 0 &&
    (crop[1] as number) >= 0 &&
    (crop[2] as number) > 0 &&
    (crop[3] as number) > 0 &&
    (crop[0] as number) + (crop[2] as number) <= 1 + 1e-9 &&
    (crop[1] as number) + (crop[3] as number) <= 1 + 1e-9;
  if (!ok) throw new RangeError(`backgrounds: page ${slotNumber} has a crop that is not four numbers inside the photo, got ${JSON.stringify(crop)}`);
  return { image, crop: crop as unknown as Crop, ...whole };
}

/**
 * The notes kinds of the other apps (shared/LANGUAGE.md), which the phone does not offer: a page saved as
 * one (by an earlier version) loads as a photo page, which sends nothing until it is given a photo.
 */
const NOTES_KINDS: readonly string[] = ['board', 'message'];

/** Settings from their JSON; what is missing gets its default, a value that cannot be right is a RangeError. */
export function parseSettings(json: unknown): Settings {
  if (typeof json !== 'object' || json === null || Array.isArray(json)) throw new RangeError('settings must be an object');
  const raw = json as Record<string, unknown>;
  const settings = defaultSettings();
  for (const [key, saved] of Object.entries((raw.pages ?? {}) as Record<string, unknown>)) {
    const kind = NOTES_KINDS.includes(saved as string) ? 'photo' : saved;
    if (!PAGE_KINDS.includes(kind as PageKind)) throw new RangeError(`page ${key}: unknown kind ${JSON.stringify(kind)}`);
    settings.pages = { ...settings.pages, [slot(key)]: kind as PageKind };
  }
  if (raw.grain !== undefined) {
    if (typeof raw.grain !== 'number' || !(raw.grain > 0 && raw.grain <= 1)) throw new RangeError(`grain is a number above 0 and up to 1, got ${JSON.stringify(raw.grain)}`);
    settings.grain = raw.grain;
  }
  if (raw.colours !== undefined) {
    if (!COLOUR_MODES.includes(raw.colours as ColourMode)) throw new RangeError(`colours is natural or classic, got ${JSON.stringify(raw.colours)}`);
    settings.colours = raw.colours as ColourMode;
  } else {
    // Saved before the colour choice (Paperhue 0.3, also its backups): 自然 at 標準, whatever the grain was.
    // It is the rule for choosing 自然 (setColours), applied once; the next save stores the colours.
    settings.grain = STANDARD_GRAIN;
  }
  for (const [key, mark] of Object.entries((raw.lastSent ?? {}) as Record<string, unknown>)) {
    if (typeof mark !== 'string') throw new RangeError(`lastSent: page ${key} needs a text fingerprint`);
    settings.lastSent[slot(key)] = mark;
  }
  for (const [key, background] of Object.entries((raw.backgrounds ?? {}) as Record<string, unknown>)) {
    const page = slot(key);
    settings.backgrounds[page] = parseBackground(page, background);
  }
  if (raw.lastBackup !== undefined && raw.lastBackup !== null) {
    if (typeof raw.lastBackup !== 'string' || Number.isNaN(Date.parse(raw.lastBackup))) throw new RangeError('lastBackup must be a date');
    settings.lastBackup = raw.lastBackup;
  }
  return settings;
}

/**
 * `settings` with the colours switched to `colours`. Choosing 自然 / Natural also sets the grain to 標準,
 * which the user can change afterwards; choosing 經典 / Classic keeps the grain.
 */
export function setColours(settings: Settings, colours: ColourMode): Settings {
  if (settings.colours === colours) return settings;
  return { ...settings, colours, ...(colours === 'natural' ? { grain: STANDARD_GRAIN } : {}) };
}

/** `settings` with page `page` set to `kind`. What is kept for the page (its photo, the card sent there) stays, for when it changes back. */
export function setPageKind(settings: Settings, page: number, kind: PageKind): Settings {
  if (settings.pages[page] === kind) return settings;
  return { ...settings, pages: { ...settings.pages, [page]: kind } };
}
