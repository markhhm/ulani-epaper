/**
 * The Store in the browser's IndexedDB (browser only). Everything stays in this browser: cards, their
 * photos, settings and the frames drawn last. iOS may clear a site's data after a while without use,
 * so the app treats it as a cache and offers backup files.
 *
 * Object stores: `meta` (key `cards` -> the card list, key `settings`), `backgrounds` (file name ->
 * bytes), `frames` (card id -> {sig, frame}). Bytes are stored as ArrayBuffers (older Safari
 * versions cannot keep Blobs reliably).
 */

import type { Card } from '../core/cards';
import { parseCard } from '../core/cards';
import type { Store } from '../core/library';
import { defaultSettings, parseSettings, type Settings } from '../core/settings';

const DB_NAME = 'paperhue';
const STORES = ['meta', 'backgrounds', 'frames'] as const;
type StoreName = (typeof STORES)[number];

function wrap<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function done(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error ?? new Error('the transaction was aborted'));
  });
}

const buffer = (data: Uint8Array): ArrayBuffer => data.slice().buffer as ArrayBuffer;

class IdbStore implements Store {
  constructor(private readonly db: IDBDatabase) {}

  private async get<T>(store: StoreName, key: string): Promise<T | undefined> {
    return (await wrap(this.db.transaction(store).objectStore(store).get(key))) as T | undefined;
  }

  private async put(store: StoreName, key: string, value: unknown): Promise<void> {
    const tx = this.db.transaction(store, 'readwrite');
    tx.objectStore(store).put(value, key);
    await done(tx);
  }

  private async remove(store: StoreName, key: string): Promise<void> {
    const tx = this.db.transaction(store, 'readwrite');
    tx.objectStore(store).delete(key);
    await done(tx);
  }

  async getCards(): Promise<Card[]> {
    const raw = await this.get<unknown[]>('meta', 'cards');
    return (raw ?? []).map((c) => parseCard(c));
  }

  setCards(cards: Card[]): Promise<void> {
    return this.put('meta', 'cards', JSON.parse(JSON.stringify(cards)));
  }

  async getBackground(file: string): Promise<Uint8Array | undefined> {
    const data = await this.get<ArrayBuffer>('backgrounds', file);
    return data ? new Uint8Array(data) : undefined;
  }

  setBackground(file: string, data: Uint8Array): Promise<void> {
    return this.put('backgrounds', file, buffer(data));
  }

  deleteBackground(file: string): Promise<void> {
    return this.remove('backgrounds', file);
  }

  async getSettings(): Promise<Settings> {
    const raw = await this.get<unknown>('meta', 'settings');
    return raw === undefined ? defaultSettings() : parseSettings(raw);
  }

  setSettings(settings: Settings): Promise<void> {
    return this.put('meta', 'settings', JSON.parse(JSON.stringify(settings)));
  }

  async getFrame(id: string, sig: string): Promise<Uint8Array | undefined> {
    const kept = await this.get<{ sig: string; frame: ArrayBuffer }>('frames', id);
    return kept?.sig === sig ? new Uint8Array(kept.frame) : undefined;
  }

  setFrame(id: string, sig: string, frame: Uint8Array): Promise<void> {
    return this.put('frames', id, { sig, frame: buffer(frame) });
  }

  deleteFrame(id: string): Promise<void> {
    return this.remove('frames', id);
  }

  async replaceAll(all: { cards: Card[]; backgrounds: ReadonlyMap<string, Uint8Array>; settings: Settings }): Promise<void> {
    const tx = this.db.transaction([...STORES], 'readwrite');
    for (const name of STORES) tx.objectStore(name).clear();
    tx.objectStore('meta').put(JSON.parse(JSON.stringify(all.cards)), 'cards');
    tx.objectStore('meta').put(JSON.parse(JSON.stringify(all.settings)), 'settings');
    for (const [file, data] of all.backgrounds) tx.objectStore('backgrounds').put(buffer(data), file);
    await done(tx);
  }
}

/** Open the store; rejects where the browser has no IndexedDB or refuses it (the app then keeps things in memory). */
export async function openIdbStore(): Promise<Store> {
  if (typeof indexedDB === 'undefined') throw new Error('this browser has no IndexedDB');
  const request = indexedDB.open(DB_NAME, 1);
  request.onupgradeneeded = () => {
    for (const name of STORES) request.result.createObjectStore(name);
  };
  const db = await wrap(request);
  // Another tab upgrading or the browser closing the database: reopen on the next load.
  db.onversionchange = () => db.close();
  return new IdbStore(db);
}

/** Ask the browser to keep this site's data (it may say no, and iOS may clear it anyway). */
export async function askToKeepData(): Promise<boolean> {
  try {
    return (await navigator.storage?.persist?.()) ?? false;
  } catch {
    return false;
  }
}
