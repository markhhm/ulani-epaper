/**
 * The saved cards and settings, behind a `Store` (IndexedDB in the browser, memory in tests and where
 * the browser keeps nothing): adding, changing and removing cards, the `.paperhue-card` file for one
 * card and the backup file for everything. Cards and backgrounds stay on this device; the files are how
 * they travel.
 *
 * A card with a photo keeps the photo as `<id>.jpg` in the store: upright and at most 4K (the app's
 * photo rules, applied by the `prepare` function it passes in), so a crop applies to the stored photo.
 */

import { type Card, CardError, newCardId, parseCard } from './cards';
import { checkCrop } from './crop';
import { photoSizeFromHeader } from './photo';
import { defaultSettings, parseSettings, type Settings } from './settings';
import { openZip, writeZip, type ZipEntry } from './zip';

/** A photo that went through the photo rules: JPEG bytes, upright, at most 4K, and its size. */
export interface PreparedPhoto {
  readonly jpeg: Uint8Array;
  readonly width: number;
  readonly height: number;
}

/** Turns the bytes of any photo file into a PreparedPhoto, or throws (a photo over 50 MP, not a photo). */
export type PreparePhoto = (bytes: Uint8Array) => Promise<PreparedPhoto>;

/** Where cards, backgrounds, settings and drawn frames are kept. */
export interface Store {
  /** Newest first. */
  getCards(): Promise<Card[]>;
  setCards(cards: Card[]): Promise<void>;
  getBackground(file: string): Promise<Uint8Array | undefined>;
  setBackground(file: string, data: Uint8Array): Promise<void>;
  deleteBackground(file: string): Promise<void>;
  getSettings(): Promise<Settings>;
  setSettings(settings: Settings): Promise<void>;
  /** The frame drawn for a card, if it was stored for the same fingerprint `sig`. */
  getFrame(id: string, sig: string): Promise<Uint8Array | undefined>;
  setFrame(id: string, sig: string, frame: Uint8Array): Promise<void>;
  deleteFrame(id: string): Promise<void>;
  /** Replace everything at once (a restore); drawn frames are dropped. */
  replaceAll(all: { cards: Card[]; backgrounds: ReadonlyMap<string, Uint8Array>; settings: Settings }): Promise<void>;
}

/** Something the library refuses: a card that is not there, a card file or backup that is not valid. */
export class LibraryError extends Error {
  override name = 'LibraryError';
}

/** A store that keeps everything in memory. */
export class MemoryStore implements Store {
  private cards: Card[] = [];
  private backgrounds = new Map<string, Uint8Array>();
  private settings: Settings = defaultSettings();
  private frames = new Map<string, { sig: string; frame: Uint8Array }>();

  async getCards() {
    return structuredClone(this.cards);
  }
  async setCards(cards: Card[]) {
    this.cards = structuredClone(cards);
  }
  async getBackground(file: string) {
    return this.backgrounds.get(file);
  }
  async setBackground(file: string, data: Uint8Array) {
    this.backgrounds.set(file, data);
  }
  async deleteBackground(file: string) {
    this.backgrounds.delete(file);
  }
  async getSettings() {
    return structuredClone(this.settings);
  }
  async setSettings(settings: Settings) {
    this.settings = structuredClone(settings);
  }
  async getFrame(id: string, sig: string) {
    const kept = this.frames.get(id);
    return kept?.sig === sig ? kept.frame : undefined;
  }
  async setFrame(id: string, sig: string, frame: Uint8Array) {
    this.frames.set(id, { sig, frame });
  }
  async deleteFrame(id: string) {
    this.frames.delete(id);
  }
  async replaceAll(all: { cards: Card[]; backgrounds: ReadonlyMap<string, Uint8Array>; settings: Settings }) {
    this.cards = structuredClone(all.cards);
    this.backgrounds = new Map(all.backgrounds);
    this.settings = structuredClone(all.settings);
    this.frames.clear();
  }
}

const MAX_JSON_BYTES = 64 * 1024; // what a card file's card.json may hold (it is not trusted)
const MAX_IMAGE_BYTES = 40 * 1024 * 1024;
const MAX_CARDS_JSON_BYTES = 4 * 1024 * 1024; // a backup's cards.json
const EXPORT_IMAGE = 'background.jpg';

const fileOf = (id: string) => `${id}.jpg`;
const imageOf = (card: Card): string | undefined => ('image' in card.background ? card.background.image : undefined);

/**
 * `card` checked, with its photo in place: a new `photo` is kept as `<id>.jpg` (its crop checked against
 * it), without one the card must already have that file. Returns the card to save.
 */
async function withPhoto(store: Store, card: Card, photo: PreparedPhoto | undefined, current: Card | undefined): Promise<Card> {
  const bg = card.background;
  if (!('image' in bg)) return card;
  if (photo) {
    const crop = bg.crop === null ? null : checkCrop(bg.crop, photo.width, photo.height);
    return { ...card, background: { image: fileOf(card.id), crop } };
  }
  if (!current || imageOf(current) !== bg.image) throw new LibraryError('a card with a photo background needs the photo');
  const size = bg.crop ? photoSizeFromHeader((await store.getBackground(bg.image)) ?? new Uint8Array(0)) : undefined;
  if (bg.crop && size) checkCrop(bg.crop, size.width, size.height);
  return card;
}

/** Save `card` as a new card on top, under a new id (the one it has is ignored). */
export async function addCard(store: Store, card: Card, photo?: PreparedPhoto): Promise<Card> {
  const cards = await store.getCards();
  const checked = parseCard({ ...card, id: newCardId(new Set(cards.map((c) => c.id))) });
  const saved = await withPhoto(store, checked, photo, undefined);
  if (photo) await store.setBackground(fileOf(saved.id), photo.jpeg);
  await store.setCards([saved, ...cards]);
  return saved;
}

/** Replace the saved card with the same id, in place; the photo stays unless `photo` is given. */
export async function updateCard(store: Store, card: Card, photo?: PreparedPhoto): Promise<Card> {
  const cards = await store.getCards();
  const at = cards.findIndex((c) => c.id === card.id);
  if (at < 0) throw new LibraryError(`there is no card ${card.id}`);
  const current = cards[at] as Card;
  const saved = await withPhoto(store, parseCard(card), photo, current);
  if (photo) await store.setBackground(fileOf(saved.id), photo.jpeg);
  cards[at] = saved;
  await store.setCards(cards);
  await store.deleteFrame(saved.id);
  const old = imageOf(current);
  if (old && !imageOf(saved)) await store.deleteBackground(old);
  return saved;
}

/** Delete a card with its photo and its drawn frame. */
export async function removeCard(store: Store, id: string): Promise<void> {
  const cards = await store.getCards();
  const card = cards.find((c) => c.id === id);
  if (!card) throw new LibraryError(`there is no card ${id}`);
  await store.setCards(cards.filter((c) => c.id !== id));
  const image = imageOf(card);
  if (image) await store.deleteBackground(image);
  await store.deleteFrame(id);
}

function parseJson(bytes: Uint8Array, what: string): unknown {
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new LibraryError(`${what} is not valid JSON`);
  }
}

/** The card as one `.paperhue-card` file: card.json and, with a photo, background.jpg. */
export async function exportCardFile(store: Store, id: string): Promise<Uint8Array> {
  const card = (await store.getCards()).find((c) => c.id === id);
  if (!card) throw new LibraryError(`there is no card ${id}`);
  const image = imageOf(card);
  const entries: ZipEntry[] = [];
  const out = image && 'image' in card.background ? { ...card, background: { ...card.background, image: EXPORT_IMAGE } } : card;
  entries.push({ name: 'card.json', data: new TextEncoder().encode(JSON.stringify(out, null, 1)) });
  if (image) {
    const data = await store.getBackground(image);
    if (!data) throw new LibraryError(`the photo of card ${id} is missing`);
    entries.push({ name: EXPORT_IMAGE, data });
  }
  return writeZip(entries);
}

/**
 * Add the card in a `.paperhue-card` file as a new card (a new id: importing twice makes two). Its
 * photo goes through `prepare`. Refuses, and keeps nothing, when the file is not a zip, has no valid
 * card.json, names a photo that is not in it, or holds something over 64 KiB (json) or 40 MiB (photo).
 */
export async function importCardFile(store: Store, bytes: Uint8Array, prepare: PreparePhoto): Promise<Card> {
  const zip = openZip(bytes);
  const card = parseCard(parseJson(await zip.read('card.json', MAX_JSON_BYTES), 'card.json'));
  const image = imageOf(card);
  const photo = image ? await prepare(await zip.read(image, MAX_IMAGE_BYTES)) : undefined;
  return addCard(store, card, photo);
}

/** Everything as one backup file; the settings in it (and in the store) say when it was made. */
export async function exportBackup(store: Store, now: Date = new Date()): Promise<Uint8Array> {
  const cards = await store.getCards();
  const settings = { ...(await store.getSettings()), lastBackup: now.toISOString() };
  const enc = new TextEncoder();
  const entries: ZipEntry[] = [
    { name: 'settings.json', data: enc.encode(JSON.stringify(settings, null, 1)) },
    { name: 'cards.json', data: enc.encode(JSON.stringify({ version: 1, cards }, null, 1)) },
  ];
  for (const card of cards) {
    const image = imageOf(card);
    if (!image) continue;
    const data = await store.getBackground(image);
    if (!data) throw new LibraryError(`the photo of card ${card.id} is missing`);
    entries.push({ name: `backgrounds/${image}`, data });
  }
  const file = writeZip(entries);
  await store.setSettings(settings);
  return file;
}

/**
 * Replace everything with the contents of a backup file; returns the number of cards. The file is
 * checked completely first (every card, every photo through `prepare`): a file that fails changes nothing.
 */
export async function importBackup(store: Store, bytes: Uint8Array, prepare: PreparePhoto): Promise<number> {
  const zip = openZip(bytes);
  const settings = parseSettings(parseJson(await zip.read('settings.json', MAX_JSON_BYTES), 'settings.json'));
  const raw = parseJson(await zip.read('cards.json', MAX_CARDS_JSON_BYTES), 'cards.json') as { version?: unknown; cards?: unknown };
  if (raw?.version !== 1 || !Array.isArray(raw.cards)) throw new LibraryError('cards.json is not a list of cards');
  const cards: Card[] = [];
  const backgrounds = new Map<string, Uint8Array>();
  for (const json of raw.cards) {
    const card = parseCard(json);
    if (cards.some((c) => c.id === card.id)) throw new CardError(`card ${card.id} is in the backup twice`);
    const image = imageOf(card);
    if (image && 'image' in card.background) {
      const photo = await prepare(await zip.read(`backgrounds/${image}`, MAX_IMAGE_BYTES));
      const crop = card.background.crop === null ? null : checkCrop(card.background.crop, photo.width, photo.height);
      backgrounds.set(fileOf(card.id), photo.jpeg);
      card.background = { image: fileOf(card.id), crop };
    }
    cards.push(card);
  }
  await store.replaceAll({ cards, backgrounds, settings });
  return cards.length;
}
