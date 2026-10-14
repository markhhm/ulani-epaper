import { describe, expect, it } from 'vitest';
import { type Card, parseCard } from '../src/core/cards';
import {
  addCard,
  clearPageBackground,
  exportBackup,
  exportCardFile,
  importBackup,
  importCardFile,
  LibraryError,
  MemoryStore,
  type PreparedPhoto,
  removeCard,
  setPageBackground,
  updateCard,
} from '../src/core/library';
import { PhotoTooLarge } from '../src/core/photo';
import { openZip, writeZip } from '../src/core/zip';
import { defaultSettings } from '../src/core/settings';
import pythonZip from './fixtures/python-card.zip.b64?raw';

const text = (s: string) => new TextEncoder().encode(s);
const photo = (width = 1200, height = 900, fill = 7): PreparedPhoto => ({ jpeg: new Uint8Array(50).fill(fill), width, height });
/** Stands in for the browser's photo rules: any bytes are a 1200 x 900 photo, except the ones that say they are huge. */
const prepare = async (bytes: Uint8Array): Promise<PreparedPhoto> => {
  if (bytes[0] === 255) throw new PhotoTooLarge();
  return { jpeg: bytes, width: 1200, height: 900 };
};

const status = (extra: object = {}) => ({
  version: 1,
  id: '00000000',
  background: { color: 'yellow' },
  texts: [{ text: '開會中', box: [0.05, 0.12, 0.9, 0.45], size: 130 }],
  ...extra,
});
const withPhoto = (crop: number[] | null = null) => parseCard(status({ background: { image: 'x.jpg', crop } }));

const ids = async (store: MemoryStore) => (await store.getCards()).map((c) => c.id);

describe('saving cards', () => {
  it('adds a card on top under a new id', async () => {
    const store = new MemoryStore();
    const first = await addCard(store, parseCard(status()));
    const second = await addCard(store, parseCard(status()));
    expect(first.id).toMatch(/^[0-9a-f]{8}$/);
    expect(first.id).not.toBe('00000000');
    expect(await ids(store)).toEqual([second.id, first.id]);
  });

  it('keeps a photo as <id>.jpg and checks the crop against it', async () => {
    const store = new MemoryStore();
    const crop = [0, 0.1, 1, 0.8]; // the default crop of a 1200 x 900 photo
    const card = await addCard(store, withPhoto(crop), photo());
    expect(card.background).toEqual({ image: `${card.id}.jpg`, crop });
    expect(await store.getBackground(`${card.id}.jpg`)).toEqual(photo().jpeg);
    // A crop in the wrong shape for the photo is refused and nothing is kept.
    await expect(addCard(store, withPhoto([0, 0, 0.5, 0.5]), photo())).rejects.toThrow(RangeError);
    expect(await ids(store)).toEqual([card.id]);
  });

  it('refuses a card with a photo background but no photo', async () => {
    const store = new MemoryStore();
    await expect(addCard(store, withPhoto())).rejects.toThrow(/photo/);
    expect(await ids(store)).toEqual([]);
  });

  it('updates a card where it is, keeping its photo unless given another', async () => {
    const store = new MemoryStore();
    const a = await addCard(store, withPhoto(), photo(1200, 900, 1));
    const b = await addCard(store, parseCard(status()));
    // A crop in the screen's shape: 0.5 of 1200 px is 600 px wide, 0.4 of 900 px is 360 px high.
    const edited: Card = { ...a, background: { image: `${a.id}.jpg`, crop: [0.1, 0.1, 0.5, 0.4] } };
    await updateCard(store, edited);
    expect(await ids(store)).toEqual([b.id, a.id]);
    expect((await store.getCards())[1]?.background).toEqual({ image: `${a.id}.jpg`, crop: [0.1, 0.1, 0.5, 0.4] });
    expect(await store.getBackground(`${a.id}.jpg`)).toEqual(photo(1200, 900, 1).jpeg);
    await updateCard(store, { ...edited, background: { image: `${a.id}.jpg`, crop: null } }, photo(1200, 900, 2));
    expect(await store.getBackground(`${a.id}.jpg`)).toEqual(photo(1200, 900, 2).jpeg);
  });

  it('drops the photo and the cached frame when the card turns to a plain colour', async () => {
    const store = new MemoryStore();
    const a = await addCard(store, withPhoto(), photo());
    await store.setFrame(a.id, 'sig', new Uint8Array(4));
    await updateCard(store, { ...a, background: { color: 'blue' } });
    expect(await store.getBackground(`${a.id}.jpg`)).toBeUndefined();
    expect(await store.getFrame(a.id, 'sig')).toBeUndefined();
  });

  it('does not update a card that is not there', async () => {
    await expect(updateCard(new MemoryStore(), parseCard(status({ id: 'a1b2c3d4' })))).rejects.toThrow(/no card/i);
  });

  it('removes a card with its photo and its cached frame', async () => {
    const store = new MemoryStore();
    const a = await addCard(store, withPhoto(), photo());
    await store.setFrame(a.id, 'sig', new Uint8Array(4));
    await removeCard(store, a.id);
    expect(await ids(store)).toEqual([]);
    expect(await store.getBackground(`${a.id}.jpg`)).toBeUndefined();
    expect(await store.getFrame(a.id, 'sig')).toBeUndefined();
  });
});

describe('a cached frame', () => {
  it('is only given back for the fingerprint it was stored with', async () => {
    const store = new MemoryStore();
    await store.setFrame('a1b2c3d4', 'one', Uint8Array.of(1));
    expect(await store.getFrame('a1b2c3d4', 'one')).toEqual(Uint8Array.of(1));
    expect(await store.getFrame('a1b2c3d4', 'two')).toBeUndefined();
  });
});

describe('a .paperhue-card file', () => {
  it('goes out and comes back as a new card, with its photo through the photo rules', async () => {
    const source = new MemoryStore();
    const card = await addCard(source, withPhoto([0, 0.1, 1, 0.8]), photo());
    const file = await exportCardFile(source, card.id);
    const zip = openZip(file);
    expect(zip.names).toEqual(['card.json', 'background.jpg']);
    expect(JSON.parse(new TextDecoder().decode(await zip.read('card.json', 65536))).background.image).toBe('background.jpg');

    const target = new MemoryStore();
    const imported = await importCardFile(target, file, prepare);
    const twice = await importCardFile(target, file, prepare);
    expect(imported.id).not.toBe(card.id);
    expect(twice.id).not.toBe(imported.id);
    expect(imported.texts).toEqual(card.texts);
    expect(imported.background).toEqual({ image: `${imported.id}.jpg`, crop: [0, 0.1, 1, 0.8] });
    expect(await target.getBackground(`${imported.id}.jpg`)).toEqual(photo().jpeg);
  });

  it('takes a file made by the Python apps', async () => {
    const file = Uint8Array.from(atob(pythonZip.trim()), (c) => c.charCodeAt(0));
    const card = await importCardFile(new MemoryStore(), file, prepare);
    expect(card.texts[0]?.text).toBe('開會中');
    expect(card.id).not.toBe('a1b2c3d4');
  });

  it('refuses a file that is not a card file, and changes nothing', async () => {
    const store = new MemoryStore();
    const json = (o: object) => text(JSON.stringify(o));
    const good = status({ id: 'a1b2c3d4' });
    const photoCard = status({ id: 'a1b2c3d4', background: { image: 'background.jpg', crop: null } });
    const bad: [string, Uint8Array][] = [
      ['not a zip', text('hello')],
      ['no card.json', writeZip([{ name: 'other.json', data: json(good) }])],
      ['card.json that is not json', writeZip([{ name: 'card.json', data: text('{nope') }])],
      ['card.json that breaks the rules', writeZip([{ name: 'card.json', data: json(status({ texts: [{ text: '', box: [0, 0, 1, 1] }] })) }])],
      ['a background that is not in the zip', writeZip([{ name: 'card.json', data: json(photoCard) }])],
      ['card.json over 64 KiB', writeZip([{ name: 'card.json', data: text(JSON.stringify(good) + ' '.repeat(65 * 1024)) }])],
      ['a photo over the 50 MP limit', writeZip([{ name: 'card.json', data: json(photoCard) }, { name: 'background.jpg', data: Uint8Array.of(255, 216) }])],
    ];
    for (const [name, file] of bad) {
      await expect(importCardFile(store, file, prepare), name).rejects.toThrow();
      expect(await ids(store), name).toEqual([]);
    }
  });
});

describe('a backup', () => {
  it('holds the cards, their photos and the settings, and restores them on an empty store', async () => {
    const source = new MemoryStore();
    const plain = await addCard(source, parseCard(status()));
    const photoCard = await addCard(source, withPhoto(), photo(1200, 900, 5));
    await source.setSettings({ ...defaultSettings(), pages: { 1: 'card', 2: 'card', 3: 'photo', 4: 'day' }, grain: 0.8, lastSent: { 1: 'abcd1234' } });
    const now = new Date('2026-10-12T08:00:00Z');
    const file = await exportBackup(source, now);
    expect((await source.getSettings()).lastBackup).toBeNull(); // the app records it once the file reached the user

    const target = new MemoryStore();
    await target.setFrame('deadbeef', 'sig', Uint8Array.of(1));
    const count = await importBackup(target, file, prepare);
    expect(count).toBe(2);
    expect(await ids(target)).toEqual([photoCard.id, plain.id]);
    expect(await target.getBackground(`${photoCard.id}.jpg`)).toEqual(photo(1200, 900, 5).jpeg);
    expect(await target.getSettings()).toEqual({ ...(await source.getSettings()), lastBackup: now.toISOString() });
    expect(await target.getFrame('deadbeef', 'sig')).toBeUndefined(); // cached frames are not part of a restore
  });

  it('keeps the colours, and restores a backup made before the colour choice as Natural at standard grain', async () => {
    const store = new MemoryStore();
    await store.setSettings({ ...defaultSettings(), colours: 'classic', grain: 0.65 });
    const file = await exportBackup(store);
    expect(JSON.parse(new TextDecoder().decode(await openZip(file).read('settings.json', 1 << 20)))).toMatchObject({ colours: 'classic', grain: 0.65 });
    const restored = new MemoryStore();
    await importBackup(restored, file, prepare);
    expect(await restored.getSettings()).toMatchObject({ colours: 'classic', grain: 0.65 });

    const old = writeZip([
      { name: 'cards.json', data: text(JSON.stringify({ version: 1, cards: [] })) },
      { name: 'settings.json', data: text(JSON.stringify({ pages: { 1: 'month', 2: 'agenda', 3: 'card', 4: 'photo' }, grain: 0.5 })) },
    ]);
    await importBackup(restored, old, prepare);
    expect(await restored.getSettings()).toMatchObject({ colours: 'natural', grain: 1 });
  });

  it('restores a page saved as a notes board or a big message as a photo page without a photo', async () => {
    const file = writeZip([
      { name: 'cards.json', data: text(JSON.stringify({ version: 1, cards: [] })) },
      { name: 'settings.json', data: text(JSON.stringify({ pages: { 1: 'month', 2: 'board', 3: 'message', 4: 'card' } })) },
    ]);
    const store = new MemoryStore();
    await importBackup(store, file, prepare);
    expect((await store.getSettings()).pages).toEqual({ 1: 'month', 2: 'photo', 3: 'photo', 4: 'card' });
    expect((await store.getSettings()).backgrounds).toEqual({});
  });

  it('refuses a damaged or foreign file and leaves what is there alone', async () => {
    const store = new MemoryStore();
    const keep = await addCard(store, parseCard(status()));
    const cards = (list: unknown[]) => text(JSON.stringify({ version: 1, cards: list }));
    const settings = text(JSON.stringify(defaultSettings()));
    const card = status({ id: 'a1b2c3d4', background: { image: 'a1b2c3d4.jpg', crop: null } });
    const red = status({ id: 'a1b2c3d4', background: { color: 'red' } });
    const both = (cardsJson: Uint8Array, ...more: { name: string; data: Uint8Array }[]) =>
      writeZip([{ name: 'cards.json', data: cardsJson }, { name: 'settings.json', data: settings }, ...more]);
    const bad: [string, Uint8Array][] = [
      ['not a zip', text('hello')],
      ['no cards.json', writeZip([{ name: 'settings.json', data: settings }])],
      ['no settings.json', writeZip([{ name: 'cards.json', data: cards([]) }])],
      ['a card that breaks the rules', both(cards([{ ...red, id: 'zz' }]))],
      ['a card id twice', both(cards([red, red]))],
      ['a photo that is not in the zip', both(cards([card]))],
      ['settings that cannot be right', writeZip([{ name: 'cards.json', data: cards([]) }, { name: 'settings.json', data: text('{"grain": 5}') }])],
      ['a photo over the limit', both(cards([card]), { name: 'backgrounds/a1b2c3d4.jpg', data: Uint8Array.of(255, 216) })],
    ];
    for (const [name, file] of bad) {
      await expect(importBackup(store, file, prepare), name).rejects.toThrow();
      expect(await ids(store), name).toEqual([keep.id]);
    }
  });
});

describe('the photo behind a calendar page', () => {
  const crop = [0, 0.1, 1, 0.8] as const; // the default crop of a 1200 x 900 photo

  it('is kept as page-<n>.jpg with its crop, and replaced by the next one', async () => {
    const store = new MemoryStore();
    const saved = await setPageBackground(store, 1, crop, photo(1200, 900, 3));
    expect(saved).toEqual({ image: 'page-1.jpg', crop });
    expect((await store.getSettings()).backgrounds).toEqual({ 1: saved });
    expect(await store.getBackground('page-1.jpg')).toEqual(photo(1200, 900, 3).jpeg);
    await setPageBackground(store, 1, null, photo(1200, 900, 4));
    expect(await store.getBackground('page-1.jpg')).toEqual(photo(1200, 900, 4).jpeg);
    expect((await store.getSettings()).backgrounds).toEqual({ 1: { image: 'page-1.jpg', crop: null } });
  });

  it('refuses a crop that does not suit the photo and keeps what was there', async () => {
    const store = new MemoryStore();
    await setPageBackground(store, 2, crop, photo());
    await expect(setPageBackground(store, 2, [0, 0, 0.5, 0.5], photo(1200, 900, 9))).rejects.toThrow(RangeError);
    expect((await store.getSettings()).backgrounds).toEqual({ 2: { image: 'page-2.jpg', crop } });
    expect(await store.getBackground('page-2.jpg')).toEqual(photo().jpeg);
  });

  it('changes only the crop when no new photo is given, and needs a photo to do so', async () => {
    const store = new MemoryStore();
    await expect(setPageBackground(store, 3, null)).rejects.toThrow(LibraryError);
    await setPageBackground(store, 3, null, photo(1200, 900, 6));
    await setPageBackground(store, 3, crop);
    expect((await store.getSettings()).backgrounds[3]).toEqual({ image: 'page-3.jpg', crop });
    expect(await store.getBackground('page-3.jpg')).toEqual(photo(1200, 900, 6).jpeg);
  });

  it('is removed with its file, and only that page loses it', async () => {
    const store = new MemoryStore();
    await setPageBackground(store, 1, null, photo());
    await setPageBackground(store, 2, null, photo());
    await clearPageBackground(store, 1);
    expect((await store.getSettings()).backgrounds).toEqual({ 2: { image: 'page-2.jpg', crop: null } });
    expect(await store.getBackground('page-1.jpg')).toBeUndefined();
    expect(await store.getBackground('page-2.jpg')).toBeDefined();
  });

  it('goes into a backup and comes back from it, through the photo rules', async () => {
    const source = new MemoryStore();
    await setPageBackground(source, 1, crop, photo(1200, 900, 3));
    await setPageBackground(source, 4, null, photo(1200, 900, 8));
    const card = await addCard(source, withPhoto(), photo(1200, 900, 5));
    const file = await exportBackup(source, new Date('2026-10-12T08:00:00Z'));
    const target = new MemoryStore();
    await importBackup(target, file, prepare);
    expect((await target.getSettings()).backgrounds).toEqual({ 1: { image: 'page-1.jpg', crop }, 4: { image: 'page-4.jpg', crop: null } });
    expect(await target.getBackground('page-1.jpg')).toEqual(photo(1200, 900, 3).jpeg);
    expect(await target.getBackground('page-4.jpg')).toEqual(photo(1200, 900, 8).jpeg);
    expect(await target.getBackground(`${card.id}.jpg`)).toEqual(photo(1200, 900, 5).jpeg);
  });

  it('keeps the whole-photo fit of a photo page through a new crop, a new photo and a backup', async () => {
    const source = new MemoryStore();
    await setPageBackground(source, 4, null, photo(1200, 900, 3));
    await source.setSettings({ ...(await source.getSettings()), backgrounds: { 4: { image: 'page-4.jpg', crop: null, fit: 'contain' } } });
    await setPageBackground(source, 4, crop);
    await setPageBackground(source, 4, crop, photo(1200, 900, 4));
    expect((await source.getSettings()).backgrounds).toEqual({ 4: { image: 'page-4.jpg', crop, fit: 'contain' } });
    const target = new MemoryStore();
    await importBackup(target, await exportBackup(source), prepare);
    expect((await target.getSettings()).backgrounds).toEqual({ 4: { image: 'page-4.jpg', crop, fit: 'contain' } });
  });

  it('is checked when a backup is restored: a missing photo, a crop that does not fit, a photo over the limit', async () => {
    const store = new MemoryStore();
    const keep = await addCard(store, parseCard(status()));
    const withSettings = (backgrounds: object, ...more: { name: string; data: Uint8Array }[]) =>
      writeZip([
        { name: 'cards.json', data: text(JSON.stringify({ version: 1, cards: [] })) },
        { name: 'settings.json', data: text(JSON.stringify({ ...defaultSettings(), backgrounds })) },
        ...more,
      ]);
    const photoFile = { name: 'backgrounds/page-1.jpg', data: new Uint8Array(50) };
    const bad: [string, Uint8Array][] = [
      ['a photo that is not in the zip', withSettings({ 1: { image: 'page-1.jpg', crop: null } })],
      ['a crop that does not suit the photo', withSettings({ 1: { image: 'page-1.jpg', crop: [0, 0, 0.5, 0.5] } }, photoFile)],
      ['a photo over the limit', withSettings({ 1: { image: 'page-1.jpg', crop: null } }, { ...photoFile, data: Uint8Array.of(255, 216) })],
    ];
    for (const [name, file] of bad) {
      await expect(importBackup(store, file, prepare), name).rejects.toThrow();
      expect(await ids(store), name).toEqual([keep.id]);
    }
  });
});
