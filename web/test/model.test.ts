import { describe, expect, it } from 'vitest';
import { type Card, parseCard } from '../src/core/cards';
import { MemoryStore } from '../src/core/library';
import { FRAME_BYTES } from '../src/core/protocol';
import { AppModel, type DeviceSession, type ModelDeps } from '../src/app/model';
import type { UploadResult } from '../src/session/session';

const frameFor = (card: Card) => new Uint8Array(FRAME_BYTES).fill(card.texts[0]?.text.charCodeAt(0) ?? 0);
const make = (id: string, text: string): Card =>
  parseCard({ version: 1, id, background: { color: 'white' }, texts: [{ text, box: [0, 0, 1, 0.5] }] });
const AWAY = make('a1b2c3d4', 'A');
const MEETING = make('b1b2c3d4', 'B');

class FakeSession implements DeviceSession {
  name = 'Desk';
  connected = true;
  calls: string[] = [];
  stored = new Map<number, Uint8Array>();
  closed = false;
  shown = 1;
  async currentSlot() {
    return { slot: this.shown, crc32: 0 };
  }
  async pushPages(frames: ReadonlyMap<number, Uint8Array>) {
    const results = new Map<number, UploadResult>();
    for (const [slot, frame] of frames) {
      this.calls.push(`push ${slot}`);
      this.stored.set(slot, frame);
      results.set(slot, 'ok');
    }
    return results;
  }
  async show(slot: number) {
    this.calls.push(`show ${slot}`);
    this.shown = slot;
  }
  async battery() {
    return { level: 4, charging: false };
  }
  onDisconnect() {
    return () => undefined;
  }
  async close() {
    this.closed = true;
  }
}

function setup(overrides: Partial<ModelDeps> = {}) {
  const session = new FakeSession();
  const store = new MemoryStore();
  const drawn: string[] = [];
  const connections: number[] = [];
  const deps: ModelDeps = {
    store,
    drawCard: async (card) => {
      drawn.push(card.id);
      return frameFor(card);
    },
    connect: async () => {
      connections.push(1);
      return session;
    },
    now: () => new Date('2026-10-12T08:00:00Z'),
    ...overrides,
  };
  return { model: new AppModel(deps), session, store, drawn, connections };
}

async function withCardPages(model: AppModel, ...pages: number[]) {
  for (const page of pages) await model.setPageKind(page, 'card');
}

describe('the app model', () => {
  it('loads the cards and settings from the store', async () => {
    const { model, store } = setup();
    await store.setCards([AWAY]);
    await model.load();
    expect(model.state.ready).toBe(true);
    expect(model.state.cards.map((c) => c.id)).toEqual(['a1b2c3d4']);
    expect(model.state.settings.pages[4]).toBe('photo');
  });

  it('keeps the page plan and the grain', async () => {
    const { model, store } = setup();
    await model.load();
    await model.setPageKind(2, 'card');
    await model.setGrain(0.8);
    const saved = await store.getSettings();
    expect(saved.pages[2]).toBe('card');
    expect(saved.grain).toBe(0.8);
    expect(model.state.settings.grain).toBe(0.8);
  });

  it('shows an error and keeps the old settings when the browser cannot save them', async () => {
    const { model, store } = setup();
    await model.load();
    const refuse = new DOMException('full', 'QuotaExceededError');
    store.setSettings = async () => {
      throw refuse;
    };
    await model.setPageKind(2, 'card');
    await model.setGrain(0.5);
    expect(model.state.error).toBe(refuse);
    expect(model.state.settings.pages[2]).toBe('agenda');
    expect(model.state.settings.grain).toBe(1);
  });

  it('pushes a card: connects, draws it once, sends it and remembers where it went', async () => {
    const { model, session, store, drawn, connections } = setup();
    await model.load();
    await withCardPages(model, 2, 3);
    await model.pushCard(AWAY);
    expect(connections).toHaveLength(1);
    expect(session.calls).toEqual(['push 2', 'show 2']); // page 1 is on screen, so the lowest card page
    expect(model.state.error).toBeUndefined();
    expect(model.state.job).toBeUndefined();
    expect(Object.keys((await store.getSettings()).lastSent)).toEqual(['2']);
    expect(model.state.link.connected).toBe(true);
    expect(model.state.refreshUntil).toBe(new Date('2026-10-12T08:00:45Z').getTime());
    expect(model.state.notice).toEqual({ kind: 'card', slot: 2, unchanged: false, redraws: true });

    await model.pushCard(AWAY);
    expect(drawn).toEqual(['a1b2c3d4']); // the drawn frame was kept
    expect(connections).toHaveLength(1); // and the connection
  });

  it('draws a card again after it was saved with a change', async () => {
    const { model, drawn } = setup();
    await model.load();
    await withCardPages(model, 2);
    const saved = await model.saveCard(AWAY);
    await model.pushCard(saved);
    await model.saveCard({ ...saved, texts: [{ ...(saved.texts[0] as Card['texts'][0]), text: 'Z' }] });
    await model.pushCard(model.state.cards[0] as Card);
    expect(drawn).toEqual([saved.id, saved.id]);
  });

  it('offers to make a page a card page when there is none, without connecting', async () => {
    const { model, session, connections } = setup();
    await model.load();
    await model.pushCard(AWAY);
    expect(connections).toHaveLength(0);
    expect(model.state.offer).toEqual({ slot: 4, card: AWAY });
    await model.confirmOffer();
    expect(model.state.settings.pages[4]).toBe('card');
    expect(model.state.offer).toBeUndefined();
    expect(session.calls).toEqual(['push 4', 'show 4']);
  });

  it('can be told no, and then nothing changes', async () => {
    const { model } = setup();
    await model.load();
    await model.pushCard(AWAY);
    model.dismissOffer();
    expect(model.state.offer).toBeUndefined();
    expect(model.state.settings.pages[4]).toBe('photo');
  });

  it('shows what went wrong and is usable again', async () => {
    const boom = new Error('no device');
    const { model } = setup({ connect: async () => { throw boom; } });
    await model.load();
    await withCardPages(model, 2);
    await model.pushCard(AWAY);
    expect(model.state.error).toBe(boom);
    expect(model.state.job).toBeUndefined();
    model.clearError();
    expect(model.state.error).toBeUndefined();
  });

  it('shows an error from anywhere in the app until it is dismissed', async () => {
    const { model } = setup();
    const error = new Error('bad file');
    model.reportError(error);
    expect(model.state.error).toBe(error);
    model.clearError();
    expect(model.state.error).toBeUndefined();
  });

  it('preloads the first cards onto the card pages in one push, without switching', async () => {
    const { model, session } = setup();
    await model.load();
    await withCardPages(model, 2, 3);
    await model.preload([AWAY, MEETING]);
    expect(session.calls).toEqual(['push 2', 'push 3']);
    expect(session.stored.get(3)).toEqual(frameFor(MEETING));
    expect(model.state.notice).toEqual({ kind: 'preload', count: 2 });
    expect(model.state.settings.lastSent).toEqual({ 2: expect.any(String), 3: expect.any(String) });
    // Now each card knows its page.
    expect(model.pageOf(AWAY)).toBe(2);
    expect(model.pageOf(MEETING)).toBe(3);
    expect(model.pageOf(make('c1b2c3d4', 'C'))).toBeUndefined();
  });

  it('sends a photo frame to a page and switches to it', async () => {
    const { model, session } = setup();
    await model.load();
    await model.sendFrame(4, new Uint8Array(FRAME_BYTES).fill(9));
    expect(session.calls).toEqual(['push 4', 'show 4']);
    expect(model.state.notice).toEqual({ kind: 'photo', slot: 4, unchanged: false, redraws: true });
  });

  it('sends a calendar page: draws the kind of the page, sends it, switches to it', async () => {
    const drawn: string[] = [];
    const { model, session } = setup({
      drawCalendar: async (kind) => {
        drawn.push(kind);
        return new Uint8Array(800 * 480).fill(1);
      },
    });
    await model.load();
    await model.sendCalendarPage(2); // page 2 is 本日行程＋一週行程 by default
    expect(drawn).toEqual(['agenda']);
    expect(session.calls).toEqual(['push 2', 'show 2']);
    expect(model.state.notice).toEqual({ kind: 'calendar', slot: 2, unchanged: false, redraws: true });
    expect(model.state.error).toBeUndefined();
  });

  it('sends nothing for a page that is not a calendar page, or when the calendar cannot be drawn', async () => {
    const { model, session } = setup({
      drawCalendar: async () => {
        throw new Error('no calendar');
      },
    });
    await model.load();
    await model.sendCalendarPage(4); // photo page
    expect(session.calls).toEqual([]);
    expect(model.state.job).toBeUndefined();
    await model.sendCalendarPage(1);
    expect(session.calls).toEqual([]);
    expect((model.state.error as Error).message).toBe('no calendar');
  });

  it('says when the device already shows the card, and when only the page was switched', async () => {
    const { model, session } = setup();
    await model.load();
    await withCardPages(model, 2, 3);
    await model.pushCard(AWAY); // page 2, switched to it
    session.stored.set(2, frameFor(AWAY));
    session.pushPages = async (frames) => new Map([...frames.keys()].map((slot) => [slot, 'unchanged' as UploadResult]));
    await model.pushCard(AWAY);
    expect(model.state.notice).toEqual({ kind: 'card', slot: 2, unchanged: true, redraws: false });
    session.shown = 1;
    await model.pushCard(AWAY);
    expect(model.state.notice).toEqual({ kind: 'card', slot: 2, unchanged: true, redraws: true });
  });

  it('says nothing about an earlier job once a new one starts', async () => {
    const { model } = setup();
    await model.load();
    await withCardPages(model, 2);
    await model.pushCard(AWAY);
    expect(model.state.notice).toBeDefined();
    const wait = model.pushCard(MEETING);
    expect(model.state.notice).toBeUndefined();
    await wait;
  });

  it('shows connecting attempts and the wait for a redraw while connecting, and nothing after', async () => {
    const seen: unknown[] = [];
    let model!: AppModel;
    const session = new FakeSession();
    ({ model } = setup({
      connect: async (onLink) => {
        onLink({ type: 'waiting', until: 5 });
        seen.push(model.state.link.activity);
        onLink({ type: 'attempt', attempt: 2 });
        seen.push(model.state.link.activity);
        onLink({ type: 'failed', attempt: 2, error: new Error('x'), droppedWhileConnecting: false });
        seen.push(model.state.link.activity);
        return session;
      },
    }));
    await model.load();
    await model.connect();
    expect(seen).toEqual([{ type: 'waiting', until: 5 }, { type: 'attempt', attempt: 2 }, undefined]);
    expect(model.state.link.activity).toBeUndefined();
  });

  it('lets go of the device when told to', async () => {
    const { model, session } = setup();
    await model.load();
    await model.connect();
    expect(model.state.link).toMatchObject({ connected: true, name: 'Desk', battery: { level: 4, charging: false } });
    await model.disconnect();
    expect(session.closed).toBe(true);
    expect(model.state.link.connected).toBe(false);
  });

});
