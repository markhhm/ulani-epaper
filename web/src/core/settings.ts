/**
 * What the app remembers besides the cards: the page plan, the grain of the dithering and the
 * fingerprint of the frame last sent to each card page. Kept in the browser's IndexedDB and in
 * backups (settings.json).
 */

import { DEFAULT_PAGES, PAGE_KINDS, type PageKind, type PagePlan } from './pages';
import { USER_SLOTS } from './protocol';

/** Grain levels offered in every app: the share of the dithering error that is spread. */
export const GRAIN_LEVELS = Object.freeze([
  { key: 'standard', strength: 1 },
  { key: 'soft', strength: 0.8 },
  { key: 'softer', strength: 0.65 },
  { key: 'smoothest', strength: 0.5 },
] as const);

export interface Settings {
  pages: PagePlan;
  /** Dithering strength, above 0 and at most 1. */
  grain: number;
  /** Page (1-4) -> fingerprint of the card frame this app last put there. */
  lastSent: Record<number, string>;
  /** When the last backup file was made (ISO time), or null. */
  lastBackup: string | null;
}

export function defaultSettings(): Settings {
  return { pages: { ...DEFAULT_PAGES }, grain: 1, lastSent: {}, lastBackup: null };
}

function slot(key: string): number {
  const n = Number(key);
  if (!USER_SLOTS.includes(n)) throw new RangeError(`pages are 1-4, got ${JSON.stringify(key)}`);
  return n;
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
