import { describe, expect, it } from 'vitest';
import { AppModel, type DeviceSession } from '../../src/app/model';
import { backgroundSync } from '../../src/background/sync';
import { type AgendaData, fixedZone, parseAgenda } from '../../src/core/agenda';
import { MemoryStore } from '../../src/core/library';
import { FeedError } from '../../src/core/sources';
import { ConnectFailed, type UploadResult } from '../../src/session/session';

const CALENDAR: AgendaData = parseAgenda({ v: 1, events: [], reminders: [] }, fixedZone(480));

const device: DeviceSession = {
  name: 'Desk',
  connected: true,
  currentSlot: async () => ({ slot: 1 }),
  pushPages: async (frames) => new Map<number, UploadResult>([...frames.keys()].map((slot) => [slot, slot === 1 ? 'unchanged' : 'ok'])),
  show: async () => undefined,
  battery: async () => ({ level: 4, charging: false }),
  onDisconnect: () => () => undefined,
  close: async () => undefined,
};

function model(reconnect: () => Promise<DeviceSession | undefined>) {
  return new AppModel({
    store: new MemoryStore(),
    drawCard: async () => new Uint8Array(0),
    connect: () => Promise.reject(new Error('no chooser in the background')),
    drawCalendar: async () => new Uint8Array(800 * 480),
    reconnect,
  });
}

describe('the background sync page', () => {
  it('sends the calendar pages to the remembered device and reports what changed', async () => {
    expect(await backgroundSync(model(async () => device), async () => CALENDAR)).toEqual({ outcome: 'done', updated: [2, 3], unchanged: [1] });
  });

  it('reports a device out of reach, so the service tries again later', async () => {
    const away = model(() => Promise.reject(new ConnectFailed(1, new Error('no answer'), false)));
    expect(await backgroundSync(away, async () => CALENDAR)).toEqual({ outcome: 'notFound' });
  });

  it('sends nothing when a calendar cannot be read, and names the feed only', async () => {
    const result = await backgroundSync(model(async () => device), () => Promise.reject(new FeedError('http', '工作', 404)));
    expect(result).toEqual({ outcome: 'feedError', feed: '工作', reason: 'http', status: 404 });
  });
});
