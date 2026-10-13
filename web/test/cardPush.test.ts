import { describe, expect, it } from 'vitest';
import { cardSlot, frameHash, NoCardPage, preloadCards, pushCard, pushToPage, type CardDevice } from '../src/core/cardPush';
import { FRAME_BYTES } from '../src/core/protocol';
import type { UploadResult, WaitOptions } from '../src/session/session';

/** A frame that is all one palette index, so different cards have different frames. */
const frame = (index: number) => new Uint8Array(FRAME_BYTES).fill(index * 17);
const AWAY = frame(1);
const MEETING = frame(2);
const LUNCH = frame(3);

const PAGES = { 1: 'month', 2: 'card', 3: 'card', 4: 'photo' } as const;

/** What the device shows and holds, and every call it gets: an image it already holds is skipped, like the real one. */
class FakeDevice implements CardDevice {
  calls: string[] = [];
  waits: (WaitOptions | undefined)[] = [];
  stored = new Map<number, Uint8Array>();
  constructor(public shown: number) {}

  async currentSlot(wait?: WaitOptions) {
    this.calls.push('currentSlot');
    this.waits.push(wait);
    return { slot: this.shown, crc32: 0 };
  }

  async pushPages(frames: ReadonlyMap<number, Uint8Array>) {
    const results = new Map<number, UploadResult>();
    for (const [slot, data] of frames) {
      const same = this.stored.get(slot)?.every((b, i) => b === data[i]) ?? false;
      this.stored.set(slot, data);
      results.set(slot, same ? 'unchanged' : 'ok');
      this.calls.push(`push ${slot}`);
    }
    return results;
  }

  async show(slot: number) {
    this.calls.push(`show ${slot}`);
    this.shown = slot;
  }
}

describe('which page a pushed card goes to', () => {
  it('stays on the page it is already on, else the card page on screen, else the lowest card page', () => {
    expect(cardSlot([2, 3], [3], 2)).toBe(3);
    expect(cardSlot([2, 3], [2, 3], 3)).toBe(3);
    expect(cardSlot([2, 3], [], 3)).toBe(3);
    expect(cardSlot([2, 3], [], 1)).toBe(2);
    expect(cardSlot([2, 3], [3], 1)).toBe(3);
  });
});

describe('reading the page on screen before a push', () => {
  it('waits for a busy or redrawing device as the push does (Send right after Show on device)', async () => {
    const options = { signal: new AbortController().signal, busyTimeoutMs: 1234 };
    const device = new FakeDevice(1);
    await pushToPage(device, 4, AWAY, options);
    await pushCard(device, { pages: PAGES, lastSent: {} }, MEETING, options);
    expect(device.waits).toEqual([options, options]);
  });
});

describe('pushing a card', () => {
  it('replaces the card page on screen', async () => {
    const device = new FakeDevice(3);
    const done = await pushCard(device, { pages: PAGES, lastSent: {} }, AWAY);
    expect(device.calls).toEqual(['currentSlot', 'push 3']);
    expect(done).toMatchObject({ slot: 3, results: new Map([[3, 'ok']]) });
    expect(done.lastSent).toEqual({ 3: frameHash(AWAY) });
  });

  it('goes to the lowest card page when no card page is on screen, and switches to it', async () => {
    const device = new FakeDevice(1);
    const done = await pushCard(device, { pages: PAGES, lastSent: {} }, AWAY);
    expect(device.calls).toEqual(['currentSlot', 'push 2', 'show 2']);
    expect(done.slot).toBe(2);
  });

  it('only switches the page for a card that is already on one', async () => {
    const device = new FakeDevice(1);
    const settings = { pages: PAGES, lastSent: {} };
    const preloaded = await preloadCards(device, settings, [AWAY, MEETING]);
    expect(device.calls).toEqual(['push 2', 'push 3']);
    device.calls = [];
    device.shown = 2;
    const done = await pushCard(device, { ...settings, lastSent: preloaded.lastSent }, MEETING);
    expect(done.slot).toBe(3);
    // The device skips the image it holds, so nothing is uploaded again.
    expect(done.results.get(3)).toBe('unchanged');
    expect(device.calls).toEqual(['currentSlot', 'push 3', 'show 3']);
    expect(done.lastSent).toEqual({ 2: frameHash(AWAY), 3: frameHash(MEETING) });
  });

  it('does not take an edited card for the preloaded one', async () => {
    const device = new FakeDevice(2);
    const lastSent = { 2: frameHash(AWAY), 3: frameHash(MEETING) };
    const done = await pushCard(device, { pages: PAGES, lastSent }, frame(9));
    expect(done.slot).toBe(2); // not on the device: the card page on screen is replaced
  });

  it('keeps the card of a page that is not a card page for now, for when it is one again', async () => {
    const device = new FakeDevice(3);
    const pages = { 1: 'month', 2: 'photo', 3: 'card', 4: 'photo' } as const;
    const done = await pushCard(device, { pages, lastSent: { 2: frameHash(MEETING), 3: 'old' } }, AWAY);
    expect(device.calls).toEqual(['currentSlot', 'push 3']); // page 2 is not a card page now: the card goes to page 3
    expect(done.lastSent).toEqual({ 2: frameHash(MEETING), 3: frameHash(AWAY) });
  });

  it('says which page to offer when no page is a card page, before touching the device', async () => {
    const device = new FakeDevice(1);
    const offer = (pages: Record<number, string>) => pushCard(device, { pages: pages as never, lastSent: {} }, AWAY);
    await expect(offer({ 1: 'month', 2: 'agenda', 3: 'todo', 4: 'photo' })).rejects.toMatchObject({ name: 'NoCardPage', suggestedSlot: 4 });
    await expect(offer({ 1: 'photo', 2: 'month', 3: 'day', 4: 'todo' })).rejects.toMatchObject({ suggestedSlot: 1 });
    await expect(offer({ 1: 'month', 2: 'agenda', 3: 'todo', 4: 'day' })).rejects.toBeInstanceOf(NoCardPage);
    await expect(offer({ 1: 'month', 2: 'agenda', 3: 'todo', 4: 'day' })).rejects.toMatchObject({ suggestedSlot: 4 });
    expect(device.calls).toEqual([]);
  });
});

describe('preloading cards', () => {
  it('fills the card pages in order in one push, without switching', async () => {
    const device = new FakeDevice(1);
    const pages = { 1: 'month', 2: 'card', 3: 'card', 4: 'card' } as const;
    const done = await preloadCards(device, { pages, lastSent: {} }, [AWAY, MEETING, LUNCH]);
    expect(device.calls).toEqual(['push 2', 'push 3', 'push 4']);
    expect(done.lastSent).toEqual({ 2: frameHash(AWAY), 3: frameHash(MEETING), 4: frameHash(LUNCH) });
  });

  it('refuses more cards than card pages before it touches the device', async () => {
    const device = new FakeDevice(1);
    await expect(preloadCards(device, { pages: PAGES, lastSent: {} }, [AWAY, MEETING, LUNCH])).rejects.toThrow(/3.*2/);
    await expect(preloadCards(device, { pages: { 1: 'month', 2: 'month', 3: 'month', 4: 'month' }, lastSent: {} }, [AWAY])).rejects.toBeInstanceOf(NoCardPage);
    expect(device.calls).toEqual([]);
  });
});

describe('the fingerprint of a frame', () => {
  it('differs for different frames and is a short hex string', () => {
    expect(frameHash(AWAY)).toMatch(/^[0-9a-f]{8}$/);
    expect(frameHash(AWAY)).not.toBe(frameHash(MEETING));
    expect(frameHash(AWAY)).toBe(frameHash(frame(1)));
  });
});

describe('whether the panel redraws', () => {
  it('redraws when the page on screen gets a new image or another page is switched to, not when nothing changes', async () => {
    const state = { pages: PAGES, lastSent: {} };
    expect((await pushCard(new FakeDevice(3), state, AWAY)).refreshing).toBe(true); // replaced on screen
    expect((await pushCard(new FakeDevice(1), state, AWAY)).refreshing).toBe(true); // another page: switched
    const same = new FakeDevice(3);
    same.stored.set(3, AWAY);
    expect((await pushCard(same, state, AWAY)).refreshing).toBe(false); // already there and on screen
  });
});

describe('putting a picture on a page', () => {
  it('uploads it and switches to the page when it is not on screen', async () => {
    const device = new FakeDevice(1);
    const done = await pushToPage(device, 4, AWAY);
    expect(device.calls).toEqual(['currentSlot', 'push 4', 'show 4']);
    expect(done).toMatchObject({ slot: 4, refreshing: true });
  });

  it('only uploads when the page is on screen', async () => {
    const device = new FakeDevice(4);
    await pushToPage(device, 4, AWAY);
    expect(device.calls).toEqual(['currentSlot', 'push 4']);
  });
});
