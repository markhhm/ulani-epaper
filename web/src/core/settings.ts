/**
 * What the app remembers besides the cards: the page plan, the grain of the dithering, the photo
 * behind each calendar page and the fingerprint of the frame last sent to each card page. Kept in the
 * browser's IndexedDB and in backups (settings.json).
 */

import type { Crop } from './crop';
import { DEFAULT_PAGES, PAGE_KINDS, type PageKind, type PagePlan } from './pages';
import { USER_SLOTS } from './protocol';

/** Grain levels offered in every app: the share of the dithering error that is spread. */
export const GRAIN_LEVELS = Object.freeze([
  { key: 'standard', strength: 1 },
  { key: 'soft', strength: 0.8 },
  { key: 'softer', strength: 0.65 },
  { key: 'smoothest', strength: 0.5 },
] as const);

/** The photo behind a calendar page, or of a photo page: its file in the store (always `page-<page>.jpg`) and the part of it that is shown. */
export interface PageBackground {
  image: string;
  crop: Crop | null;
}

/** The store's file name for the photo behind page `slot`. */
export const backgroundFile = (slot: number): string => `page-${slot}.jpg`;

export interface Settings {
  pages: PagePlan;
  /** Dithering strength, above 0 and at most 1. */
  grain: number;
  /** Page (1-4) -> fingerprint of the card frame this app last put there. */
  lastSent: Record<number, string>;
  /** When the last backup file was made (ISO time), or null. */
  lastBackup: string | null;
  /** Page (1-4) -> the photo its calendar page is drawn on, or that its photo page shows. */
  backgrounds: Record<number, PageBackground>;
}

export function defaultSettings(): Settings {
  return { pages: { ...DEFAULT_PAGES }, grain: 1, lastSent: {}, lastBackup: null, backgrounds: {} };
}

function slot(key: string): number {
  const n = Number(key);
  if (!USER_SLOTS.includes(n)) throw new RangeError(`pages are 1-4, got ${JSON.stringify(key)}`);
  return n;
}

/** A crop's four numbers, lying inside the photo; whether it fits the photo is checked where the photo is (core/library.ts). */
function parseBackground(slotNumber: number, value: unknown): PageBackground {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new RangeError(`backgrounds: page ${slotNumber} needs an object`);
  const { image, crop } = value as Record<string, unknown>;
  if (image !== backgroundFile(slotNumber)) throw new RangeError(`backgrounds: the photo of page ${slotNumber} is ${backgroundFile(slotNumber)}, got ${JSON.stringify(image)}`);
  if (crop === undefined || crop === null) return { image, crop: null };
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
  return { image, crop: crop as unknown as Crop };
}

/** Settings from their JSON; what is missing gets its default, a value that cannot be right is a RangeError. */
export function parseSettings(json: unknown): Settings {
  if (typeof json !== 'object' || json === null || Array.isArray(json)) throw new RangeError('settings must be an object');
  const raw = json as Record<string, unknown>;
  const settings = defaultSettings();
  for (const [key, kind] of Object.entries((raw.pages ?? {}) as Record<string, unknown>)) {
    if (!PAGE_KINDS.includes(kind as PageKind)) throw new RangeError(`page ${key}: unknown kind ${JSON.stringify(kind)}`);
    settings.pages = { ...settings.pages, [slot(key)]: kind as PageKind };
  }
  if (raw.grain !== undefined) {
    if (typeof raw.grain !== 'number' || !(raw.grain > 0 && raw.grain <= 1)) throw new RangeError(`grain is a number above 0 and up to 1, got ${JSON.stringify(raw.grain)}`);
    settings.grain = raw.grain;
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

/** `settings` with page `page` set to `kind`; what was sent to a page that changes kind is forgotten. */
export function setPageKind(settings: Settings, page: number, kind: PageKind): Settings {
  if (settings.pages[page] === kind) return settings;
  const lastSent = { ...settings.lastSent };
  delete lastSent[page];
  return { ...settings, pages: { ...settings.pages, [page]: kind }, lastSent };
}
