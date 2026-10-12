import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { type Logger, type ProtocolCharacteristic, TransportError } from '../../src/ble/transport';
import type { WriteMethod, WriteModeSetting } from '../../src/ble/webBluetooth';
import { CMD_DISCONNECT, CMD_UNLOCK, FRAME_BYTES, OP_BATTERY } from '../../src/core/protocol';
import { same } from '../../src/i18n';
import { NoReply, type SessionOptions, UploadFailed } from '../../src/session/session';
import { HOLIDAY_FEED_URL } from '../../src/spike/calendarFeed';
import { type BrowserEnv, deviceWriteMethodsVerdict } from '../../src/spike/checks';
import {
  defaultUploadPage,
  describeFeed,
  Diagnostics,
  type DiagnosticsOptions,
  type LinkActivity,
  type UploadReport,
  type UploadSettings,
} from '../../src/spike/diagnostics';
import { DroppedWhileRedrawing, isAbort, NotConnected } from '../../src/spike/errors';
import { testCardFrame } from '../../src/spike/testCard';
import { type CalendarScript, FakeCalendar, settle } from '../session/fakeCalendar';

/** A fake calendar whose transport takes the settings WebBluetoothTransport takes. */
class TunableCalendar extends FakeCalendar {
  writeMode: WriteModeSetting = 'auto';
  logger: Logger | undefined;
}

/** A transport that, like WebBluetoothTransport, tells the write methods of the real characteristic. */
class WebLikeCalendar extends TunableCalendar {
  methods: Readonly<Record<WriteMethod, boolean>> = {
    writeValueWithoutResponse: true,
    writeValueWithResponse: true,
    writeValue: true,
  };

  writeMethods(characteristic: ProtocolCharacteristic): Readonly<Record<WriteMethod, boolean>> | undefined {
    return this.connected && characteristic === 'image' ? this.methods : undefined;
  }
}

/** A browser like Bluefy: Web Bluetooth, but no global BluetoothRemoteGATTCharacteristic. */
const BLUEFY: BrowserEnv = {
  bluetooth: { requestDevice: () => Promise.reject(new Error('not in tests')), getAvailability: async () => true },
  isSecureContext: true,
  protocol: 'https:',
  characteristicClass: undefined,
  userAgent: 'Bluefy/3.9.3',
};

const QUICK: Omit<SessionOptions, 'log'> = { replyTimeoutMs: 50, resultTimeoutMs: 500, busyRetryDelayMs: 10 };

const SETTINGS: UploadSettings = { page: 1, writeMode: 'auto', chunkSize: 180, flushEvery: 10 };

function setUp(script: CalendarScript = {}, options: DiagnosticsOptions = {}) {
  const calendar = new TunableCalendar(script);
  const diagnostics = new Diagnostics({
    createTransport: () => calendar,
    session: QUICK,
    connect: { attempts: 2, retryDelayMs: 10 },
    now: () => Date.now(),
    ...options,
  });
  return { calendar, diagnostics };
}

async function connected(script: CalendarScript = {}, options: DiagnosticsOptions = {}) {
  const parts = setUp(script, options);
  await settle(parts.diagnostics.connect());
  return parts;
}

function messages(diagnostics: Diagnostics): string[] {
  return diagnostics.log.entries().map((entry) => entry.message);
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date(2026, 9, 12, 14, 3, 22));
});

afterEach(() => {
  vi.useRealTimers();
});

describe('connect', () => {
  it('reaches the transport synchronously, so a click still counts as a user gesture', async () => {
    const { calendar, diagnostics } = setUp();
    const pending = diagnostics.connect();
    expect(calendar.connectCalls).toBe(1);
    await settle(pending);
  });

  it('connects, unlocks, reads model and firmware, and logs through the page log', async () => {
    const { calendar, diagnostics } = setUp();
    const changes = vi.fn();
    diagnostics.onChange(changes);
    const device = await settle(diagnostics.connect());
    expect(device).toEqual({ name: 'Fake Calendar 000000', kind: 'fake', model: 'P7320E-B', firmware: 'v1.0.09' });
    expect(calendar.commands()[0]).toEqual(CMD_UNLOCK);
    expect(diagnostics.session).toBeDefined();
    expect(diagnostics.connected).toBe(true);
    expect(diagnostics.checklist.get('connect')).toMatchObject({ status: 'pass', note: same('Fake Calendar 000000') });
    expect(diagnostics.checklist.get('deviceInfo')).toMatchObject({ status: 'pass', note: same('P7320E-B, v1.0.09') });
    expect(calendar.logger).toBe(diagnostics.log.logger);
    expect(messages(diagnostics)).toContain('> 04 4e 42');
    expect(changes).toHaveBeenCalled();
  });

  it('warns when the firmware cannot be read (the flush read would fail)', async () => {
    const { calendar, diagnostics } = setUp();
    const read = calendar.read.bind(calendar);
    calendar.read = async (characteristic) => {
      if (characteristic === 'firmwareRevision') throw new TransportError('unsupported', 'firmwareRevision cannot be read');
      return read(characteristic);
    };
    const device = await settle(diagnostics.connect());
    expect(device.firmware).toBeUndefined();
    expect(device.firmwareError).toBeInstanceOf(TransportError);
    expect(diagnostics.checklist.get('deviceInfo').status).toBe('warn');
    expect(diagnostics.checklist.get('deviceInfo').note['zh-TW']).toContain('不同步');
    expect(diagnostics.checklist.get('deviceInfo').note.en).toContain('"off"');
  });

  it('fails the check with an explanation in both languages when connecting fails', async () => {
    const { calendar, diagnostics } = setUp();
    calendar.connectFailures.push(new TransportError('bondLost', 'encryption refused'));
    const error = await settle(diagnostics.connect()).catch((reason: unknown) => reason);
    expect(error).toBeInstanceOf(TransportError);
    expect(diagnostics.session).toBeUndefined();
    expect(diagnostics.checklist.get('connect').status).toBe('fail');
    expect(diagnostics.checklist.get('connect').note['zh-TW']).toContain('配對');
    expect(diagnostics.checklist.get('connect').note.en).toContain('pairing');
    expect(messages(diagnostics).some((line) => line.includes('encryption refused'))).toBe(true);
  });

  it('shows the pairing-mode hint after the first attempt the device drops, until a connection works', async () => {
    const { calendar, diagnostics } = setUp();
    calendar.connectFailures.push(
      new TransportError('linkLost', 'the device disconnected', { droppedWhileConnecting: true }),
    );
    const seen: boolean[] = [];
    diagnostics.onChange(() => seen.push(diagnostics.pairingHint));
    expect(diagnostics.pairingHint).toBe(false);
    const pending = diagnostics.connect();
    await vi.advanceTimersByTimeAsync(0); // the first attempt failed; the retry waits
    expect(diagnostics.pairingHint).toBe(true);
    expect(seen).toContain(true);
    await settle(pending);
    expect(diagnostics.pairingHint).toBe(false);
  });

  it('keeps the pairing-mode hint when connecting gave up after such a drop', async () => {
    const { calendar, diagnostics } = setUp();
    const drop = () => new TransportError('linkLost', 'the device disconnected', { droppedWhileConnecting: true });
    calendar.connectFailures.push(drop(), drop());
    await settle(diagnostics.connect()).catch(() => undefined);
    expect(diagnostics.pairingHint).toBe(true);
    expect(diagnostics.checklist.get('connect').status).toBe('fail');
    expect(diagnostics.checklist.get('connect').note.en).toContain('(pairing mode), then connect again');
  });

  it('does not show the pairing-mode hint for attempts that fail otherwise', async () => {
    const { calendar, diagnostics } = setUp();
    calendar.connectFailures.push(new TransportError('timeout', 'connecting took longer than 15 s'));
    await settle(diagnostics.connect());
    expect(diagnostics.pairingHint).toBe(false);
  });

  it('tells which attempt is running, and nothing once connected', async () => {
    const { calendar, diagnostics } = setUp();
    calendar.connectFailures.push(new TransportError('timeout', 'connecting took longer than 15 s'));
    const activity: (LinkActivity | undefined)[] = [];
    diagnostics.onChange(() => activity.push(diagnostics.linkActivity));
    await settle(diagnostics.connect());
    expect(activity).toContainEqual({ type: 'attempt', attempt: 1 });
    expect(activity).toContainEqual({ type: 'attempt', attempt: 2 });
    expect(diagnostics.linkActivity).toBeUndefined();
  });

  it('ignores progress from the connection it replaced', async () => {
    const transports: FakeCalendar[] = [];
    /** While set, new transports connect only once it resolves (the chooser is open). */
    let chooser: Promise<void> | undefined;
    const diagnostics = new Diagnostics({
      createTransport: () => {
        const calendar = new TunableCalendar({ shown: 3 });
        const gate = chooser;
        if (gate) {
          const connect = calendar.connect.bind(calendar);
          calendar.connect = async (options) => {
            await gate;
            return connect(options);
          };
        }
        transports.push(calendar);
        return calendar;
      },
      session: QUICK,
      connect: { attempts: 2, retryDelayMs: 10 },
      now: () => Date.now(),
    });
    await settle(diagnostics.connect());
    await settle(diagnostics.showPage(2));
    await vi.advanceTimersByTimeAsync(20_000);
    transports[0]?.drop(); // the page waits for the refresh to end before reconnecting
    await vi.advanceTimersByTimeAsync(1_000);
    expect(diagnostics.linkActivity?.type).toBe('waiting');
    const seen: (LinkActivity | undefined)[] = [];
    diagnostics.onChange(() => seen.push(diagnostics.linkActivity));
    // Connect again while the chooser stays open: the new attempt runs, the old reconnect is cancelled.
    let choose!: () => void;
    chooser = new Promise<void>((resolve) => {
      choose = resolve;
    });
    const connecting = diagnostics.connect();
    await vi.advanceTimersByTimeAsync(0);
    expect(diagnostics.linkActivity).toEqual({ type: 'attempt', attempt: 1 });
    expect(seen.at(-1)).toEqual({ type: 'attempt', attempt: 1 });
    choose();
    await settle(connecting);
    expect(diagnostics.connected).toBe(true);
    expect(diagnostics.linkActivity).toBeUndefined();
  });

  it('does not show the pairing-mode hint for a reconnect attempt the device drops', async () => {
    const { calendar, diagnostics } = await connected();
    calendar.drop();
    calendar.connectFailures.push(
      new TransportError('linkLost', 'the device disconnected', { droppedWhileConnecting: true }),
    );
    const seen: boolean[] = [];
    diagnostics.onChange(() => seen.push(diagnostics.pairingHint));
    expect((await settle(diagnostics.readStatus())).battery?.level).toBe(4);
    expect(calendar.connectCalls).toBe(3); // the first connect, the dropped attempt, the one that worked
    expect(seen).not.toContain(true);
    expect(diagnostics.pairingHint).toBe(false);
  });

  it('closes the link of the previous connection before opening a new one', async () => {
    const transports: FakeCalendar[] = [];
    const diagnostics = new Diagnostics({
      createTransport: () => {
        const calendar = new TunableCalendar();
        transports.push(calendar);
        return calendar;
      },
      session: QUICK,
      now: () => Date.now(),
    });
    await settle(diagnostics.connect());
    const first = transports[0] as FakeCalendar;
    expect(first.connected).toBe(true);
    // E.g. tapped while the page's reconnect is still unlocking its new link:
    // in Chrome both connections share the device's GATT server.
    const pending = diagnostics.connect();
    expect(first.connected).toBe(false);
    expect(transports[1]?.connectCalls).toBe(1);
    await settle(pending);
    expect(diagnostics.connected).toBe(true);
    expect(first.commands().map((data) => data[0])).not.toContain(CMD_DISCONNECT[0]);
  });

  it('notices a dropped link', async () => {
    const { calendar, diagnostics } = await connected();
    const changes = vi.fn();
    diagnostics.onChange(changes);
    calendar.drop();
    expect(diagnostics.connected).toBe(false);
    expect(diagnostics.session).toBeDefined();
    expect(changes).toHaveBeenCalled();
    expect(messages(diagnostics)).toContain('the link dropped; the next action reconnects');
    // Not during a refresh: nothing reconnects until the next action.
    await vi.advanceTimersByTimeAsync(120_000);
    expect(calendar.connectCalls).toBe(1);
  });
});

describe('write methods on the device', () => {
  it('checks the write methods again on the device characteristic once connected (Bluefy)', async () => {
    const calendar = new WebLikeCalendar();
    const diagnostics = new Diagnostics({ createTransport: () => calendar, session: QUICK, now: () => Date.now() });
    await diagnostics.checkBrowser(BLUEFY);
    expect(diagnostics.checklist.get('writeMethods').status).toBe('info');
    await settle(diagnostics.connect());
    expect(diagnostics.deviceWriteMethods).toEqual(calendar.methods);
    expect(diagnostics.checklist.get('writeMethods')).toEqual({
      id: 'writeMethods',
      ...deviceWriteMethodsVerdict(calendar.methods),
    });
    expect(diagnostics.checklist.get('writeMethods').status).toBe('pass');
    expect(messages(diagnostics)).toContain(
      'image characteristic write methods: writeValueWithoutResponse=yes, writeValueWithResponse=yes, writeValue=yes',
    );
  });

  it('keeps the device answer when the browser is checked again', async () => {
    const calendar = new WebLikeCalendar();
    const diagnostics = new Diagnostics({ createTransport: () => calendar, session: QUICK, now: () => Date.now() });
    await settle(diagnostics.connect());
    await diagnostics.checkBrowser(BLUEFY);
    expect(diagnostics.checklist.get('writeMethods').status).toBe('pass');
    expect(diagnostics.checklist.get('writeMethods').note).toEqual(deviceWriteMethodsVerdict(calendar.methods).note);
  });

  it('warns when the device characteristic lacks writeValueWithoutResponse', async () => {
    const calendar = new WebLikeCalendar();
    calendar.methods = { writeValueWithoutResponse: false, writeValueWithResponse: true, writeValue: true };
    const diagnostics = new Diagnostics({ createTransport: () => calendar, session: QUICK, now: () => Date.now() });
    await settle(diagnostics.connect());
    expect(diagnostics.checklist.get('writeMethods').status).toBe('warn');
  });

  it('leaves the browser verdict where the transport cannot tell', async () => {
    const { diagnostics } = setUp();
    await diagnostics.checkBrowser(BLUEFY);
    await settle(diagnostics.connect());
    expect(diagnostics.deviceWriteMethods).toBeUndefined();
    expect(diagnostics.checklist.get('writeMethods').status).toBe('info');
  });
});

describe('panel refresh', () => {
  it('remembers the refresh after switching the page, and says it in the log', async () => {
    const { diagnostics } = await connected({ shown: 3 });
    expect(diagnostics.refreshStartedAt).toBeUndefined();
    await settle(diagnostics.showPage(2));
    expect(diagnostics.refreshStartedAt).toBe(Date.now());
    // When the page reconnects if the link dropped: one countdown, not two that disagree.
    expect(diagnostics.refreshEndsAt).toBe(Date.now() + 45_000);
    expect(messages(diagnostics)).toContain(
      'page 2 is on screen: the device redraws its screen now (about 40 s) and may drop the link meanwhile; it reconnects by itself',
    );
  });

  it('treats the drop during the refresh as expected and reconnects once the refresh should be over', async () => {
    const { calendar, diagnostics } = await connected({ shown: 3 });
    await settle(diagnostics.showPage(2));
    const shownAt = Date.now();
    await vi.advanceTimersByTimeAsync(20_000);
    calendar.drop(); // as the device does 14-25 s into a refresh
    await vi.advanceTimersByTimeAsync(0);
    expect(messages(diagnostics)).not.toContain('the link dropped; the next action reconnects');
    expect(messages(diagnostics)).toContain(
      'the device dropped the link while redrawing its screen, as expected; reconnecting after the refresh',
    );
    expect(diagnostics.checklist.get('switch').status).toBe('pass');
    expect(diagnostics.linkActivity).toEqual({ type: 'waiting', until: shownAt + 45_000 });
    await settle(diagnostics.reconnection());
    expect(calendar.connectTimes.at(-1)).toBe(shownAt + 45_000);
    expect(diagnostics.connected).toBe(true);
    expect(diagnostics.linkActivity).toBeUndefined();
    expect(diagnostics.reconnectError).toBeUndefined();
    expect(messages(diagnostics)).toContain('reconnected after the refresh');
    // Unlocked again: the next action goes straight through.
    expect((await settle(diagnostics.readStatus())).slot?.slot).toBe(2);
  });

  it('remembers the refresh after uploading to the page on screen', async () => {
    const { calendar, diagnostics } = await connected({ shown: 2 });
    await settle(diagnostics.readStatus());
    await settle(diagnostics.sendTestCard({ ...SETTINGS, page: 2 }));
    const uploadedAt = Date.now();
    expect(diagnostics.refreshStartedAt).toBe(uploadedAt);
    calendar.drop();
    await vi.advanceTimersByTimeAsync(0);
    expect(diagnostics.linkActivity).toEqual({ type: 'waiting', until: uploadedAt + 45_000 });
    await settle(diagnostics.reconnection());
    expect(diagnostics.connected).toBe(true);
  });

  it('does not treat a drop long after the refresh as expected', async () => {
    const { calendar, diagnostics } = await connected({ shown: 3 });
    await settle(diagnostics.showPage(2));
    await vi.advanceTimersByTimeAsync(61_000);
    calendar.drop();
    await vi.advanceTimersByTimeAsync(120_000);
    expect(messages(diagnostics)).toContain('the link dropped; the next action reconnects');
    expect(calendar.connectCalls).toBe(1);
  });

  it('reports a reconnect after the refresh that fails, for the next action to try again', async () => {
    const { calendar, diagnostics } = await connected({ shown: 3 });
    await settle(diagnostics.showPage(2));
    calendar.connectFailures.push(new TransportError('bondLost', 'encryption refused'));
    calendar.drop();
    await settle(diagnostics.reconnection());
    expect(diagnostics.reconnectError).toBeInstanceOf(TransportError);
    expect(diagnostics.connected).toBe(false);
    expect(diagnostics.linkActivity).toBeUndefined();
    expect(messages(diagnostics).some((line) => line.includes('reconnecting after the refresh failed'))).toBe(true);
    expect((await settle(diagnostics.readStatus())).slot?.slot).toBe(2);
    expect(diagnostics.reconnectError).toBeUndefined();
  });

  it('ends the refresh countdown when the reconnect may start, also with other timing', async () => {
    const { diagnostics } = await connected({ shown: 3 }, { connect: { attempts: 2, retryDelayMs: 10, refreshWaitMs: 30_000 } });
    await settle(diagnostics.showPage(2));
    expect(diagnostics.refreshEndsAt).toBe(Date.now() + 30_000);
  });

  it('sends right after switching the page: rides out the expected drop and uploads after the refresh', async () => {
    const { calendar, diagnostics } = await connected({ shown: 3, refreshMs: 40_000 }, { session: {} });
    await settle(diagnostics.showPage(2));
    const shownAt = Date.now();
    const sending = diagnostics.sendTestCard(SETTINGS);
    sending.catch(() => undefined);
    await vi.advanceTimersByTimeAsync(20_000);
    calendar.drop(); // as the device does 14-25 s into a refresh
    const report = await settle(sending);
    expect(report.outcome).toBe('ok');
    expect(calendar.connectTimes.at(-1)).toBe(shownAt + 45_000);
    expect(diagnostics.checklist.get('upload').status).toBe('pass');
    await settle(diagnostics.reconnection());
    expect(diagnostics.connected).toBe(true);
    expect(diagnostics.reconnectError).toBeUndefined();
  });

  it('reports a status read cut off by the expected drop as a warning that says it reconnects by itself', async () => {
    const { calendar, diagnostics } = await connected({ shown: 3, refreshMs: 40_000 }, { session: {} });
    await settle(diagnostics.showPage(2));
    await vi.advanceTimersByTimeAsync(15_000);
    const reading = diagnostics.readStatus();
    reading.catch(() => undefined);
    await vi.advanceTimersByTimeAsync(2_000);
    calendar.drop(); // 17 s into the refresh, while the battery query waits for its reply
    await vi.advanceTimersByTimeAsync(0);
    const battery = diagnostics.checklist.get('battery');
    expect(battery.status).toBe('warn');
    expect(battery.note.en).toContain('it reconnects by itself');
    expect(battery.note.en).not.toContain('Connect');
    expect(battery.note['zh-TW']).toContain('會自動重新連線');
    expect(battery.note['zh-TW']).not.toContain('連線」');
    const status = await settle(reading);
    expect(status.batteryError).toBeInstanceOf(DroppedWhileRedrawing);
    expect(((status.batteryError as Error).cause as TransportError).code).toBe('linkLost');
    // The page on screen is read once the page has reconnected.
    expect(status.slot?.slot).toBe(2);
  });

  it('still fails a status read cut off by a drop outside a refresh', async () => {
    const { calendar, diagnostics } = await connected({ silent: [OP_BATTERY] }, { session: { replyTimeoutMs: 5_000 } });
    const reading = diagnostics.readStatus();
    reading.catch(() => undefined);
    await vi.advanceTimersByTimeAsync(1_000);
    calendar.drop();
    const status = await settle(reading);
    expect((status.batteryError as TransportError).code).toBe('linkLost');
    expect(diagnostics.checklist.get('battery').status).toBe('fail');
  });

  it('stops at once an upload that waits behind the page’s reconnect', async () => {
    const { calendar, diagnostics } = await connected({ shown: 3 });
    await settle(diagnostics.showPage(2));
    await vi.advanceTimersByTimeAsync(20_000);
    calendar.drop(); // the page reconnects 25 s from now
    const controller = new AbortController();
    let report: UploadReport | undefined;
    void diagnostics.sendTestCard(SETTINGS, { signal: controller.signal }).then((result) => {
      report = result;
    });
    await vi.advanceTimersByTimeAsync(1_000);
    controller.abort();
    await vi.advanceTimersByTimeAsync(0);
    expect(report?.outcome).toBe('error');
    expect(isAbort(report?.error)).toBe(true);
    expect(diagnostics.checklist.get('upload').status).toBe('warn');
    await settle(diagnostics.reconnection());
    expect(calendar.headerSlots).toEqual([]);
  });

  it('reports Stop as stopped while the upload itself reconnects', async () => {
    const { calendar, diagnostics } = await connected();
    calendar.drop(); // not during a refresh: the upload reconnects
    calendar.connectFailures.push(new TransportError('notFound', 'not advertising'));
    const controller = new AbortController();
    let report: UploadReport | undefined;
    void diagnostics.sendTestCard(SETTINGS, { signal: controller.signal }).then((result) => {
      report = result;
    });
    await vi.advanceTimersByTimeAsync(5); // between attempts (10 ms apart)
    controller.abort();
    await vi.advanceTimersByTimeAsync(0);
    expect(isAbort(report?.error)).toBe(true);
    expect(diagnostics.checklist.get('upload').status).toBe('warn');
    expect(diagnostics.checklist.get('upload').note.en).toMatch(/^stopped/);
  });

  it('stops the reconnect when disconnecting', async () => {
    const { calendar, diagnostics } = await connected({ shown: 3 });
    await settle(diagnostics.showPage(2));
    calendar.drop();
    await vi.advanceTimersByTimeAsync(1_000);
    await settle(diagnostics.disconnect());
    await vi.advanceTimersByTimeAsync(120_000);
    expect(calendar.connectCalls).toBe(1);
    expect(diagnostics.linkActivity).toBeUndefined();
    expect(diagnostics.reconnectError).toBeUndefined();
  });
});

describe('status and pages', () => {
  it('reads the battery and the page on screen', async () => {
    const { diagnostics } = await connected({ shown: 3, battery: 4 });
    const status = await settle(diagnostics.readStatus());
    expect(status.battery).toEqual({ level: 4, charging: false });
    expect(status.slot).toEqual({ slot: 3, crc32: 0xdeadbeef });
    expect(diagnostics.shown).toBe(3);
    expect(diagnostics.checklist.get('battery')).toMatchObject({ status: 'pass', note: same('4 / 5') });
    expect(diagnostics.checklist.get('page')).toMatchObject({ status: 'pass', note: { 'zh-TW': '第 3 頁', en: 'Page 3' } });
  });

  it('reports each part of the status separately', async () => {
    const { diagnostics } = await connected({ silent: [OP_BATTERY], shown: 2 });
    const status = await settle(diagnostics.readStatus());
    expect(status.batteryError).toBeInstanceOf(NoReply);
    expect(status.slot?.slot).toBe(2);
    expect(diagnostics.checklist.get('battery').status).toBe('fail');
    expect(diagnostics.checklist.get('page').status).toBe('pass');
  });

  it('switches the page on screen', async () => {
    const { calendar, diagnostics } = await connected({ shown: 3 });
    await settle(diagnostics.showPage(2));
    expect(calendar.shown).toBe(2);
    expect(diagnostics.shown).toBe(2);
    expect(diagnostics.checklist.get('switch').status).toBe('pass');
  });

  it('picks a page that is not on screen for uploads', () => {
    expect(defaultUploadPage(undefined)).toBe(1);
    expect(defaultUploadPage(1)).toBe(2);
    expect(defaultUploadPage(3)).toBe(1);
  });

  it('needs a connection for everything after step 2', async () => {
    const { diagnostics } = setUp();
    await expect(diagnostics.readStatus()).rejects.toBeInstanceOf(NotConnected);
    await expect(diagnostics.showPage(1)).rejects.toBeInstanceOf(NotConnected);
    await expect(diagnostics.sendTestCard(SETTINGS)).rejects.toBeInstanceOf(NotConnected);
  });
});

describe('sendTestCard', () => {
  it('uploads a fresh card with the chosen chunk size, write mode and flush interval', async () => {
    const { calendar, diagnostics } = await connected({ shown: 3 });
    await settle(diagnostics.readStatus());
    const readsBefore = calendar.reads.length;
    const cards: string[] = [];
    const report = await settle(
      diagnostics.sendTestCard(
        { page: 1, writeMode: 'withResponse', chunkSize: 120, flushEvery: 5 },
        { onCard: (_, stamp) => cards.push(stamp) },
      ),
    );
    expect(report.outcome).toBe('ok');
    expect(report.stamp).toBe('2026-10-12 14:03:22');
    expect(cards).toEqual([report.stamp]);
    expect(calendar.writeMode).toBe('withResponse');
    expect(calendar.writeLength).toBe(120);
    expect(report.applied).toEqual({ writeMode: true, chunkSize: true });
    expect(report.chunkSize).toBe(120);
    const packets = calendar.imageWrites();
    expect(packets).toHaveLength(FRAME_BYTES / 120);
    expect(packets.every((packet) => packet.length === 120)).toBe(true);
    expect(report.packets).toBe(packets.length);
    expect(report.sent).toBe(FRAME_BYTES);
    // A flush read every 5 packets, except after the last one.
    expect(calendar.reads.length - readsBefore).toBe(Math.floor((packets.length - 1) / 5));
    const sent = new Uint8Array(FRAME_BYTES);
    let offset = 0;
    for (const packet of packets) {
      sent.set(packet, offset);
      offset += packet.length;
    }
    expect(sent).toEqual(testCardFrame({ page: 1, stamp: report.stamp }));
    expect(calendar.headerSlots).toEqual([1]);
    expect(report.onScreen).toBe(false);
    expect(report.refreshing).toBe(false);
    expect(diagnostics.checklist.get('upload').status).toBe('pass');
    expect(diagnostics.uploads).toEqual([report]);
  });

  it('measures setup, data and waiting time, and the throughput', async () => {
    let clock = 0;
    const { diagnostics } = await connected({}, { now: () => (clock += 10) });
    const progress: number[] = [];
    const report = await settle(
      diagnostics.sendTestCard(SETTINGS, { onProgress: ({ sent }) => progress.push(sent) }),
    );
    const packets = Math.ceil(FRAME_BYTES / 180);
    expect(progress).toHaveLength(packets);
    expect(progress[progress.length - 1]).toBe(FRAME_BYTES);
    // One clock tick before the upload, one per packet, one after the result.
    expect(report.setupMs).toBe(10);
    expect(report.dataMs).toBe(10 * (packets - 1));
    expect(report.waitMs).toBe(10);
    expect(report.totalMs).toBe(10 * (packets + 1));
    expect(report.bytesPerSecond).toBeCloseTo(((FRAME_BYTES - 180) * 1000) / (10 * (packets - 1)), 6);
  });

  it('says when the transport does not take a setting', async () => {
    const calendar = new FakeCalendar();
    const diagnostics = new Diagnostics({ createTransport: () => calendar, session: QUICK, now: () => Date.now() });
    await settle(diagnostics.connect());
    const report = await settle(diagnostics.sendTestCard(SETTINGS));
    expect(report.outcome).toBe('ok');
    expect(report.applied).toEqual({ writeMode: false, chunkSize: true });
    expect(messages(diagnostics).some((line) => line.includes('write mode auto (not supported by this transport)'))).toBe(
      true,
    );
  });

  it('resends the previous card unchanged', async () => {
    const { calendar, diagnostics } = await connected();
    const frames: Uint8Array[] = [];
    await settle(diagnostics.sendTestCard(SETTINGS, { onCard: (frame) => frames.push(frame) }));
    vi.setSystemTime(new Date(2026, 9, 12, 15, 0, 0));
    const again = await settle(
      diagnostics.sendTestCard({ ...SETTINGS, resend: true }, { onCard: (frame) => frames.push(frame) }),
    );
    expect(diagnostics.hasPreviousCard).toBe(true);
    expect(frames[1]).toBe(frames[0]);
    expect(again.stamp).toBe('2026-10-12 14:03:22');
    expect(calendar.headerSlots).toEqual([1, 1]);
    const fresh = await settle(diagnostics.sendTestCard(SETTINGS));
    expect(fresh.stamp).toBe('2026-10-12 15:00:00');
  });

  it('reports "unchanged" without sending data, as a warning', async () => {
    const { calendar, diagnostics } = await connected({ headerReply: [0x01, 0x02] });
    const report = await settle(diagnostics.sendTestCard(SETTINGS));
    expect(report.outcome).toBe('unchanged');
    expect(report.packets).toBe(0);
    expect(report.dataMs).toBeUndefined();
    expect(calendar.imageWrites()).toHaveLength(0);
    expect(diagnostics.checklist.get('upload').status).toBe('warn');
  });

  it('reports a rejected card as an error', async () => {
    const { diagnostics } = await connected({ failSlots: [2] });
    const report = await settle(diagnostics.sendTestCard({ ...SETTINGS, page: 2 }));
    expect(report.outcome).toBe('error');
    expect(report.error).toBeInstanceOf(UploadFailed);
    expect(report.waitMs).toBeUndefined();
    expect(diagnostics.checklist.get('upload').status).toBe('fail');
    expect(diagnostics.checklist.get('upload').note['zh-TW']).toContain('拒收');
  });

  it('notes that the panel refreshes after replacing the page on screen', async () => {
    const { diagnostics } = await connected({ shown: 2, refreshMs: 40_000 });
    await settle(diagnostics.readStatus());
    const report = await settle(diagnostics.sendTestCard({ ...SETTINGS, page: 2 }));
    expect(report.outcome).toBe('ok');
    expect(report.onScreen).toBe(true);
    expect(report.refreshing).toBe(true);
    expect(messages(diagnostics).some((line) => line.includes('the panel refreshes now (about 40 s)'))).toBe(true);
    expect(diagnostics.refreshStartedAt).toBe(Date.now());
  });

  it('stops when asked', async () => {
    const { calendar, diagnostics } = await connected();
    const controller = new AbortController();
    const report = await settle(
      diagnostics.sendTestCard(SETTINGS, {
        signal: controller.signal,
        onProgress: ({ sent }) => {
          if (sent >= 1_800) controller.abort();
        },
      }),
    );
    expect(report.outcome).toBe('error');
    expect(isAbort(report.error)).toBe(true);
    expect(report.sent).toBe(1_800);
    expect(calendar.imageWrites()).toHaveLength(10);
    expect(diagnostics.checklist.get('upload').status).toBe('warn');
  });
});

describe('disconnect', () => {
  it('says goodbye, disconnects and forgets the session', async () => {
    const { calendar, diagnostics } = await connected();
    await settle(diagnostics.disconnect());
    expect(calendar.commands().at(-1)).toEqual(CMD_DISCONNECT);
    expect(calendar.connected).toBe(false);
    expect(diagnostics.session).toBeUndefined();
    expect(diagnostics.connected).toBe(false);
    expect(diagnostics.checklist.get('disconnect').status).toBe('pass');
  });

  it('does nothing without a session', async () => {
    const { diagnostics } = setUp();
    await diagnostics.disconnect();
    expect(diagnostics.checklist.get('disconnect').status).toBe('pending');
  });

  it('opens a new link on the next connect', async () => {
    const transports: FakeCalendar[] = [];
    const diagnostics = new Diagnostics({
      createTransport: () => {
        const calendar = new FakeCalendar();
        transports.push(calendar);
        return calendar;
      },
      session: QUICK,
    });
    await settle(diagnostics.connect());
    await settle(diagnostics.disconnect());
    await settle(diagnostics.connect());
    expect(transports).toHaveLength(2);
    expect(diagnostics.checklist.get('disconnect').status).toBe('pending');
    expect(diagnostics.connected).toBe(true);
  });
});

describe('checkBrowser', () => {
  it('fills the four browser checks and logs the user agent', async () => {
    const { diagnostics } = setUp();
    const report = await diagnostics.checkBrowser({
      bluetooth: undefined,
      isSecureContext: true,
      protocol: 'https:',
      characteristicClass: undefined,
      userAgent: 'Test/1.0',
    });
    expect(report.webBluetooth).toBe(false);
    expect(diagnostics.checklist.get('webBluetooth').status).toBe('fail');
    expect(diagnostics.checklist.get('secureContext').status).toBe('pass');
    expect(diagnostics.checklist.get('availability').status).toBe('warn');
    expect(diagnostics.checklist.get('writeMethods').status).toBe('info');
    expect(messages(diagnostics)).toContain('user agent: Test/1.0');
  });
});

describe('downloadCalendar', () => {
  const ICS = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'BEGIN:VEVENT', 'SUMMARY:國慶日', 'END:VEVENT', 'END:VCALENDAR', ''].join('\r\n');

  it('fetches nothing until asked, then the holidays feed once, without credentials', async () => {
    const fetch = vi.fn(async () => new Response(ICS, { status: 200 }));
    const { diagnostics } = setUp({}, { fetch });
    await diagnostics.checkBrowser({
      bluetooth: undefined,
      isSecureContext: true,
      protocol: 'https:',
      characteristicClass: undefined,
      userAgent: 'Test/1.0',
    });
    await settle(diagnostics.connect());
    expect(fetch).not.toHaveBeenCalled();
    expect(diagnostics.checklist.get('calendarFeed').status).toBe('pending');

    const report = await diagnostics.downloadCalendar();
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(fetch).toHaveBeenCalledWith(HOLIDAY_FEED_URL, expect.objectContaining({ credentials: 'omit', mode: 'cors' }));
    expect(report).toMatchObject({ outcome: 'pass', status: 200, bytes: new TextEncoder().encode(ICS).length, vcalendar: true, events: 1 });
    expect(diagnostics.feed).toBe(report);
    expect(diagnostics.checklist.get('calendarFeed').status).toBe('pass');
    expect(diagnostics.checklist.get('calendarFeed').note.en).toBe(`HTTP 200, ${report.bytes} bytes, BEGIN:VCALENDAR`);
    expect(messages(diagnostics)).toContain(`calendar download: GET ${HOLIDAY_FEED_URL} (no credentials, no proxy)`);
    expect(messages(diagnostics).some((line) => line.startsWith('calendar download: PASS, HTTP 200'))).toBe(true);
  });

  it('reports a blocked download (CORS or network) as a failure with the browser error', async () => {
    const changes = vi.fn();
    const { diagnostics } = setUp({}, { fetch: async () => Promise.reject(new TypeError('Failed to fetch')) });
    diagnostics.onChange(changes);
    const report = await diagnostics.downloadCalendar();
    expect(report.outcome).toBe('blocked');
    expect(report.status).toBeUndefined();
    expect(diagnostics.checklist.get('calendarFeed')).toMatchObject({
      status: 'fail',
      note: same('BLOCKED: TypeError: Failed to fetch'),
    });
    expect(messages(diagnostics)).toContain('calendar download: BLOCKED: TypeError: Failed to fetch (0.0 s)');
    expect(changes).toHaveBeenCalled();
  });

  it('fails when the answer is not calendar data', async () => {
    const { diagnostics } = setUp({}, { fetch: async () => new Response('<html>sign in</html>', { status: 200 }) });
    const report = await diagnostics.downloadCalendar();
    expect(report).toMatchObject({ outcome: 'unexpected', status: 200, vcalendar: false, events: 0 });
    expect(diagnostics.checklist.get('calendarFeed').status).toBe('fail');
    expect(describeFeed(report)).toBe('NOT CALENDAR DATA, HTTP 200, 20 bytes, does not start with BEGIN:VCALENDAR, 0 events, 0.0 s');
  });
});
