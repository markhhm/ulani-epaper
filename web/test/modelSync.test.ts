import { describe, expect, it } from 'vitest';
import { type AgendaData, fixedZone, parseAgenda } from '../src/core/agenda';
import { MemoryStore } from '../src/core/library';
import { type CalendarKind, CALENDAR_KINDS } from '../src/core/pages';
import { AppModel, type DeviceSession, type ModelDeps } from '../src/app/model';
import { ConnectFailed, PushFailed, type UploadResult } from '../src/session/session';

const PHONE: AgendaData = parseAgenda(
  { v: 1, events: [{ title: '週會', start: '2026-10-13T09:00:00+08:00', end: '2026-10-13T10:00:00+08:00', allDay: false, calendar: '工作' }], reminders: [] },
  fixedZone(480),
);

/** A device that, like the real one, skips an image it already holds. */
class Device implements DeviceSession {
  name = 'Desk';
  connected = true;
  calls: string[] = [];
  stored = new Map<number, Uint8Array>();
  async currentSlot() {
    return { slot: 1 };
  }
  async pushPages(frames: ReadonlyMap<number, Uint8Array>) {
    const results = new Map<number, UploadResult>();
    for (const [slot, frame] of frames) {
      this.calls.push(`push ${slot}`);
      const held = this.stored.get(slot);
      results.set(slot, held?.every((byte, i) => byte === frame[i]) ? 'unchanged' : 'ok');
      this.stored.set(slot, frame);
    }
    return results;
  }
  async show(slot: number) {
    this.calls.push(`show ${slot}`);
  }
  async battery() {
    return { level: 4, charging: false };
  }
  onDisconnect() {
    return () => undefined;
  }
  async close() {}
}

function setup(overrides: Partial<ModelDeps> = {}) {
  const device = new Device();
  const store = new MemoryStore();
  const drawn: { kind: CalendarKind; calendar: AgendaData | undefined }[] = [];
  const events: string[] = [];
  const chooser: number[] = [];
  const deps: ModelDeps = {
    store,
    drawCard: async () => new Uint8Array(0),
    connect: async () => {
      chooser.push(1);
      return device;
    },
    drawCalendar: async (kind, calendar) => {
      drawn.push({ kind, calendar });
      return new Uint8Array(800 * 480).fill(CALENDAR_KINDS.indexOf(kind) + 1);
    },
    reconnect: async () => {
      events.push('reconnect');
      return device;
    },
    keepAwake: () => {
      events.push('screen on');
      return { release: () => events.push('screen off') };
    },
    now: () => new Date('2026-10-13T01:00:00Z'),
    ...overrides,
  };
  return { model: new AppModel(deps), device, store, drawn, events, chooser };
}

describe('syncing from the iPhone Shortcut', () => {
  it('draws the calendar pages from the phone’s data, reconnects without the chooser and sends only those pages', async () => {
    const { model, device, store, drawn, events, chooser } = setup();
    await model.load();
    await model.setPageKind(2, 'card'); // a card page is not touched
    await model.syncFromShortcut({ calendar: PHONE });
    expect(chooser).toEqual([]);
    expect(drawn.map((d) => d.kind)).toEqual(['month', 'todo']);
    expect(drawn.every((d) => d.calendar === PHONE)).toBe(true);
    expect(device.calls).toEqual(['push 1', 'push 3']); // no page switch
    expect(model.state.sync).toEqual({ outcome: 'done', updated: [1, 3], unchanged: [] });
    expect(model.state.error).toBeUndefined();
    expect(model.state.job).toBeUndefined();
    expect(model.state.link.connected).toBe(true);
    expect(events).toEqual(['screen on', 'reconnect', 'screen off']); // the screen stays on until the end
    // Nothing of the calendar is kept: only the page plan was saved.
    expect((await store.getSettings()).lastSent).toEqual({});
    expect(await store.getCards()).toEqual([]);
  });

  it('leaves pages the device already shows as they are', async () => {
    const { model, events } = setup();
    await model.load();
    await model.syncFromShortcut({ calendar: PHONE });
    await model.syncFromShortcut({ calendar: PHONE });
    expect(model.state.sync).toEqual({ outcome: 'done', updated: [], unchanged: [1, 2, 3] });
    expect(events.filter((e) => e === 'reconnect')).toHaveLength(1); // the link was already there
  });

  it('shows the phone’s calendar on the pages from then on', async () => {
    const { model, drawn } = setup();
    await model.load();
    expect(model.state.phoneCalendar).toBeUndefined();
    await model.syncFromShortcut({ calendar: PHONE });
    expect(model.state.phoneCalendar).toBe(true);
    await model.drawCalendar('day');
    expect(drawn.at(-1)).toEqual({ kind: 'day', calendar: PHONE });
  });

  it('gives up quietly when the device is not found', async () => {
    const { model, device, events } = setup({
      reconnect: async () => {
        throw new ConnectFailed(3, new Error('no answer'), false);
      },
    });
    await model.load();
    await model.syncFromShortcut({ calendar: PHONE });
    expect(model.state.sync).toEqual({ outcome: 'notFound' });
    expect(model.state.error).toBeUndefined();
    expect(model.state.job).toBeUndefined();
    expect(device.calls).toEqual([]);
    expect(events).toEqual(['screen on', 'screen off']);
  });

  it('says so when this browser has no remembered device', async () => {
    const { model, device } = setup({ reconnect: async () => undefined });
    await model.load();
    await model.syncFromShortcut({ calendar: PHONE });
    expect(model.state.sync).toEqual({ outcome: 'notPaired' });
    expect(device.calls).toEqual([]);
  });

  it('forgets the card of a page it fills with a calendar page, and keeps the others', async () => {
    const { model, store, device } = setup();
    await store.setSettings({ ...(await store.getSettings()), lastSent: { 2: 'aaaaaaaa', 4: 'bbbbbbbb' } }); // page 2 was a card page
    await model.load();
    await model.syncFromShortcut({ calendar: PHONE });
    expect(device.calls).toEqual(['push 1', 'push 2', 'push 3']);
    expect((await store.getSettings()).lastSent).toEqual({ 4: 'bbbbbbbb' });
    expect(model.state.settings.lastSent).toEqual({ 4: 'bbbbbbbb' });

    const failing = setup();
    await failing.store.setSettings({ ...(await failing.store.getSettings()), lastSent: { 1: 'aaaaaaaa', 2: 'cccccccc' } });
    failing.device.pushPages = async () => {
      throw new PushFailed(2, new Map([[1, 'ok' as const]]), 'page 2: the device rejected the image', new Error('crc'));
    };
    await failing.model.load();
    await failing.model.syncFromShortcut({ calendar: PHONE });
    expect((await failing.store.getSettings()).lastSent).toEqual({ 2: 'cccccccc' }); // only page 1 got its calendar page
  });

  it('reports the page that failed and what was sent before it', async () => {
    const failure = new PushFailed(2, new Map([[1, 'ok' as const]]), 'page 2: the device rejected the image', new Error('crc'));
    const { model, device } = setup();
    device.pushPages = async () => {
      throw failure;
    };
    await model.load();
    await model.syncFromShortcut({ calendar: PHONE });
    expect(model.state.sync).toEqual({ outcome: 'failed', updated: [1], unchanged: [], page: 2 });
    expect(model.state.error).toBe(failure);
  });

  it('says so when the data cannot be read or no page is a calendar page, without touching the device', async () => {
    const { model, events } = setup();
    await model.load();
    await model.syncFromShortcut({ unreadable: true });
    expect(model.state.sync).toEqual({ outcome: 'unreadable' });
    for (const page of [1, 2, 3]) await model.setPageKind(page, 'card');
    await model.syncFromShortcut({ calendar: PHONE });
    expect(model.state.sync).toEqual({ outcome: 'noPages' });
    expect(events).toEqual([]);
    model.dismissSync();
    expect(model.state.sync).toBeUndefined();
  });
});

describe('syncing pages that have a photo', () => {
  it('draws every calendar page with its own photo, in the app and in the scheduled sync alike', async () => {
    const photos: Record<string, number[] | undefined> = {};
    const { model } = setup({
      drawCalendar: async (kind, _calendar, background) => {
        photos[kind] = background && Array.from(background.photo);
        return new Uint8Array(800 * 480).fill(1);
      },
    });
    await model.load();
    await model.setPageBackground(1, null, { jpeg: Uint8Array.of(7, 7), width: 1200, height: 900 });
    await model.syncFromShortcut({ calendar: PHONE });
    expect(photos).toEqual({ month: [7, 7], agenda: undefined, todo: undefined });
  });
});
