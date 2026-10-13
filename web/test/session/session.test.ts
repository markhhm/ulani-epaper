import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { type ConnectOptions, type LogEntry, PAIRING_MODE_STEPS, TransportError } from '../../src/ble/transport';
import {
  buildImageHeader,
  CMD_BATTERY,
  CMD_DISCONNECT,
  CMD_GET_SLOT,
  CMD_UNLOCK,
  crc32,
  DeviceError,
  FRAME_BYTES,
  MAX_CHUNK,
  MIN_CHUNK,
  OP_BATTERY,
  OP_DEVICE_INFO,
  OP_GET_SLOT,
  OP_IMAGE_DATA,
  OP_IMAGE_HEADER,
  OP_SHOW_SLOT,
  OP_UNLOCK,
  ProtocolError,
  RSP_DATA_FAIL,
  RSP_HEADER_BUSY,
  RSP_HEADER_SAME_IMAGE,
} from '../../src/core/protocol';
import {
  CalendarSession,
  chunkSizeFor,
  ConnectFailed,
  connectSession,
  DeviceBusy,
  type LinkEvent,
  NoReply,
  type PushEvent,
  PushFailed,
  pushOrder,
  type SessionOptions,
  UploadFailed,
} from '../../src/session/session';
import { type CalendarScript, FakeCalendar, failure, frameOf, settle } from './fakeCalendar';

/** Short timeouts, like a test against a calendar that answers at once. */
const QUICK: SessionOptions = { replyTimeoutMs: 50, resultTimeoutMs: 500, busyRetryDelayMs: 10 };

async function started(script: CalendarScript = {}, options: SessionOptions = QUICK) {
  const calendar = new FakeCalendar(script);
  await calendar.connect();
  const session = new CalendarSession(calendar, options);
  await settle(session.start());
  return { calendar, session };
}

function hex(data: Uint8Array): string {
  return Array.from(data, (b) => b.toString(16).padStart(2, '0')).join(' ');
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe('commands', () => {
  it('start unlocks, with response, as the first write', async () => {
    const { calendar } = await started();
    expect(calendar.writes[0]).toEqual({ characteristic: 'command', data: CMD_UNLOCK, mode: 'withResponse' });
  });

  it('answers the simple queries', async () => {
    const { session } = await started();
    expect(await settle(session.battery())).toEqual({ level: 4, charging: false });
    expect(await settle(session.currentSlot())).toEqual({ slot: 3, crc32: 0xdeadbeef });
    const info = await settle(session.deviceInfo());
    expect(info).toEqual({ mac: '11:22:33:44:55:66', serial: 'SERIAL' });
    expect(await settle(session.model())).toBe('P7320E-B');
    expect(await settle(session.firmware())).toBe('v1.0.09');
  });

  it('works when replies arrive later instead of during the write', async () => {
    const { calendar, session } = await started({ replyDelayMs: 5 });
    expect((await settle(session.battery())).level).toBe(4);
    expect(await settle(session.upload(frameOf(1000), 1))).toBe('ok');
    expect(calendar.received).toBe(1000);
  });

  it('show switches the page on screen', async () => {
    const { calendar, session } = await started();
    await settle(session.show(3));
    expect(calendar.commands().map(hex)).toContain('0b 03');
  });

  it('show refuses a page outside 1-4 without writing', async () => {
    const { calendar, session } = await started();
    const writes = calendar.writes.length;
    expect(await failure(session.show(5))).toBeInstanceOf(ProtocolError);
    expect(calendar.writes).toHaveLength(writes);
  });

  it('a command without reply times out with NoReply', async () => {
    const { calendar, session } = await started({ silent: [OP_SHOW_SLOT] });
    const started_ = Date.now();
    const error = await failure(session.show(2));
    expect(error).toBeInstanceOf(NoReply);
    expect(error).toBeInstanceOf(DeviceError);
    expect((error as NoReply).opcode).toBe(OP_SHOW_SLOT);
    expect(Date.now() - started_).toBe(50);
    // Switching the page is not a query: it is never sent twice.
    expect(calendar.commandsWith(OP_SHOW_SLOT)).toHaveLength(1);
  });

  it('asks a query once more when the first try gets no reply', async () => {
    // As on the first iPhone run: right after unlock the device sent an
    // unrelated `05 00` and no reply to `06 00`; the next try was answered.
    const skip = { [OP_BATTERY]: 1, [OP_GET_SLOT]: 1, [OP_DEVICE_INFO]: 1 };
    const { calendar, session } = await started({ skipReplies: skip, stray: [0x05, 0x00] });
    expect(await settle(session.battery())).toEqual({ level: 4, charging: false });
    expect(await settle(session.currentSlot())).toEqual({ slot: 3, crc32: 0xdeadbeef });
    expect((await settle(session.deviceInfo())).serial).toBe('SERIAL');
    expect(calendar.commandsWith(OP_BATTERY)).toHaveLength(2);
    expect(calendar.commandsWith(OP_GET_SLOT)).toHaveLength(2);
    expect(calendar.commandsWith(OP_DEVICE_INFO)).toHaveLength(2);
  });

  it('gives up on a query after the second try gets no reply either', async () => {
    const { calendar, session } = await started({ silent: [OP_BATTERY] });
    const started_ = Date.now();
    const error = await failure(session.battery());
    expect(error).toBeInstanceOf(NoReply);
    expect((error as NoReply).opcode).toBe(OP_BATTERY);
    expect(calendar.commandsWith(OP_BATTERY)).toHaveLength(2);
    expect(Date.now() - started_).toBe(100);
  });

  it('skips unrelated notifications that arrive before the reply', async () => {
    // The stray "device ready" comes after the command and before the real
    // reply, so only the opcode filter can skip it.
    const { session } = await started({ stray: [0x05, 0x00] });
    expect((await settle(session.battery())).level).toBe(4);
    expect(await settle(session.upload(frameOf(100), 1))).toBe('ok');
  });

  it('drops stale replies before each command', async () => {
    const { calendar, session } = await started({ silent: [OP_BATTERY] });
    calendar.notify('command', [OP_BATTERY, 0x01]); // a late answer to nothing
    expect(await failure(session.battery())).toBeInstanceOf(NoReply);
  });

  it('rejects an unlock that is not 04 00', async () => {
    const calendar = new FakeCalendar();
    await calendar.connect();
    calendar.respond = (write, fake) => fake.notify('command', [write.data[0] ?? 0, 0x01]);
    const error = await failure(new CalendarSession(calendar, QUICK).start());
    expect(error).toBeInstanceOf(ProtocolError);
    expect((error as Error).message).toBe('unlock rejected: 04 01');
  });

  it('runs operations one at a time, in call order', async () => {
    const { calendar, session } = await started({ replyDelayMs: 5 });
    const results = await settle(Promise.all([session.battery(), session.currentSlot(), session.battery()]));
    expect(results.map((r) => ('level' in r ? 'battery' : 'slot'))).toEqual(['battery', 'slot', 'battery']);
    expect(calendar.commands().slice(1).map(hex)).toEqual(['06 00', '0c 00', '06 00']);
  });
});

describe('upload', () => {
  it('sends unlock, the header, then the frame in chunks without response', async () => {
    const { calendar, session } = await started({ writeLength: 100 });
    const frame = frameOf(768);
    const progress: [number, number][] = [];
    const result = await settle(session.upload(frame, 2, { onProgress: (sent, total) => progress.push([sent, total]) }));
    expect(result).toBe('ok');
    expect(calendar.commands().slice(1).map(hex)).toEqual([hex(CMD_UNLOCK), hex(buildImageHeader(frame, 2))]);
    const chunks = calendar.imageWrites();
    expect(Math.max(...chunks.map((c) => c.length))).toBe(100);
    expect(Uint8Array.from(chunks.flatMap((c) => [...c]))).toEqual(frame);
    expect(calendar.writes.filter((w) => w.characteristic === 'image').every((w) => w.mode === 'withoutResponse')).toBe(
      true,
    );
    expect(calendar.writes.filter((w) => w.characteristic === 'command').every((w) => w.mode === 'withResponse')).toBe(
      true,
    );
    expect(progress.at(-1)).toEqual([768, 768]);
  });

  it('reads the firmware revision every flushEvery packets, not after the last', async () => {
    const { calendar, session } = await started({ writeLength: 20 }, { ...QUICK, flushEvery: 3 });
    calendar.log.length = 0;
    expect(await settle(session.upload(frameOf(200), 1))).toBe('ok'); // 10 chunks
    expect(calendar.log.join('')).toBe('wwwrwwwrwwwrw');
    expect(calendar.reads.every((r) => r === 'firmwareRevision')).toBe(true);
  });

  it('uploads without the barrier, and says so, when the link cannot read the firmware revision', async () => {
    const entries: LogEntry[] = [];
    const { calendar, session } = await started(
      { writeLength: 20 },
      { ...QUICK, flushEvery: 3, log: (entry) => entries.push(entry) },
    );
    Object.assign(calendar, { canRead: () => false });
    calendar.log.length = 0;
    expect(await settle(session.upload(frameOf(200), 1))).toBe('ok');
    expect(calendar.log).not.toContain('r');
    expect(calendar.received).toBe(200);
    expect(entries.some((e) => e.level === 'warn' && /without the flush barrier/.test(e.message))).toBe(true);
  });

  it('keeps streaming without the barrier when the read turns out to be unsupported mid-frame', async () => {
    const { calendar, session } = await started({ writeLength: 20 }, { ...QUICK, flushEvery: 3 });
    let reads = 0;
    Object.assign(calendar, {
      read: async () => {
        reads++;
        throw new TransportError('unsupported', 'firmwareRevision cannot be read');
      },
    });
    expect(await settle(session.upload(frameOf(200), 1))).toBe('ok'); // 10 chunks
    expect(calendar.received).toBe(200);
    expect(reads).toBe(1);
  });

  it('still fails the upload when the barrier read loses the link', async () => {
    const { calendar, session } = await started({ writeLength: 20 }, { ...QUICK, flushEvery: 3 });
    Object.assign(calendar, {
      read: async () => {
        calendar.drop();
        throw new TransportError('linkLost', 'the device disconnected');
      },
    });
    const error = await failure(session.upload(frameOf(200), 1));
    expect((error as TransportError).code).toBe('linkLost');
  });

  it('flushEvery 0 disables the read barrier', async () => {
    const { calendar, session } = await started({ writeLength: 20 }, { ...QUICK, flushEvery: 0 });
    await settle(session.upload(frameOf(100), 1));
    expect(calendar.log).not.toContain('r');
  });

  it('pauses chunkDelayMs after each chunk', async () => {
    const { calendar, session } = await started({ writeLength: 20 }, { ...QUICK, chunkDelayMs: 30 });
    const before = Date.now();
    await settle(session.upload(frameOf(100), 1)); // 5 chunks
    expect(calendar.packets).toBe(5);
    expect(Date.now() - before).toBe(150);
  });

  it('returns unchanged and sends no data when the page already holds the frame', async () => {
    const { calendar, session } = await started({ headerReply: [...RSP_HEADER_SAME_IMAGE] });
    expect(await settle(session.upload(frameOf(10), 1))).toBe('unchanged');
    expect(calendar.imageWrites()).toEqual([]);
  });

  it.each([
    ['silent', { silentHeaders: 3 }],
    ['busy', { busyHeaders: 3 }],
  ] as const)('retries the header while the calendar is %s', async (_, script) => {
    const { calendar, session } = await started(script);
    expect(await settle(session.upload(frameOf(500), 1, { busyTimeoutMs: 5_000 }))).toBe('ok');
    expect(calendar.commandsWith(OP_IMAGE_HEADER)).toHaveLength(4); // 3 ignored or busy + 1 accepted
    expect(calendar.commandsWith(OP_UNLOCK)).toHaveLength(5); // start + one per attempt
    expect(calendar.received).toBe(500);
  });

  it('gives up with DeviceBusy when the calendar stays busy', async () => {
    const { calendar, session } = await started({ headerReply: [...RSP_HEADER_BUSY] });
    const error = await failure(session.upload(frameOf(10), 1, { busyTimeoutMs: 200 }));
    expect(error).toBeInstanceOf(DeviceBusy);
    expect(calendar.imageWrites()).toEqual([]);
  });

  it('gives up with DeviceBusy when the calendar stays silent', async () => {
    const { session } = await started({ silentHeaders: 10_000 });
    const before = Date.now();
    const error = await failure(session.upload(frameOf(10), 1, { busyTimeoutMs: 300 }));
    expect(error).toBeInstanceOf(DeviceBusy);
    expect((error as Error).message).toMatch(/an image for page 1 within 0\.3 s/);
    expect(Date.now() - before).toBeGreaterThanOrEqual(300);
    expect(Date.now() - before).toBeLessThan(400);
  });

  it('rides out the ~40 s refresh after the page on screen was replaced (default timing)', async () => {
    const { calendar, session } = await started({ shown: 2, refreshMs: 40_000 }, {});
    await settle(session.currentSlot());
    expect(await settle(session.upload(frameOf(300), 2))).toBe('ok');
    expect(session.refreshing).toBe(true);
    expect(calendar.refreshing).toBe(true);

    const headersBefore = calendar.commandsWith(OP_IMAGE_HEADER).length;
    const before = Date.now();
    expect(await settle(session.upload(frameOf(300, 1), 1))).toBe('ok');
    const waited = Date.now() - before;
    expect(waited).toBeGreaterThanOrEqual(40_000);
    expect(waited).toBeLessThan(60_000);
    // Silent attempts timed out on the unlock; the one after the refresh got through.
    expect(calendar.commandsWith(OP_UNLOCK).length).toBeGreaterThan(5);
    expect(calendar.commandsWith(OP_IMAGE_HEADER).length - headersBefore).toBe(1);
    expect(session.refreshing).toBe(false);
  });

  it('reports UploadFailed when the calendar rejects the data', async () => {
    const { session } = await started({ dataReply: [...RSP_DATA_FAIL] });
    const error = await failure(session.upload(frameOf(4), 1));
    expect(error).toBeInstanceOf(UploadFailed);
    expect((error as UploadFailed).slot).toBe(1);
    expect((error as UploadFailed).reply).toEqual(RSP_DATA_FAIL);
    expect((error as Error).message).toBe('page 1: the device rejected the image (02 01)');
  });

  it('stops streaming as soon as the calendar gives up', async () => {
    const { calendar, session } = await started({ writeLength: 20, failAfterPackets: 5 }, { ...QUICK, flushEvery: 0 });
    expect(await failure(session.upload(frameOf(2000), 1))).toBeInstanceOf(UploadFailed); // 100 packets
    expect(calendar.packets).toBeLessThan(10);
  });

  it('times out with NoReply when no result follows the data', async () => {
    const { session } = await started({ dataReply: null });
    const error = await failure(session.upload(frameOf(100), 1));
    expect(error).toBeInstanceOf(NoReply);
    expect((error as NoReply).opcode).toBe(OP_IMAGE_DATA);
  });

  it('rejects an unexpected header reply', async () => {
    const { session } = await started({ headerReply: [0x01, 0x07] });
    const error = await failure(session.upload(frameOf(10), 4));
    expect(error).toBeInstanceOf(ProtocolError);
    expect((error as Error).message).toBe('page 4: unexpected header reply: 01 07');
  });

  it('stops before the next chunk when the signal aborts', async () => {
    const { calendar, session } = await started({ writeLength: 20 });
    const controller = new AbortController();
    const error = await failure(
      session.upload(frameOf(400), 1, {
        signal: controller.signal,
        onProgress: (sent) => {
          if (sent >= 60) controller.abort();
        },
      }),
    );
    expect((error as Error).name).toBe('AbortError');
    expect(calendar.packets).toBe(3);
  });
});

describe('chunk size', () => {
  it.each([
    [20, 20],
    [97, 97],
    [180, 180],
    [514, MAX_CHUNK],
    [5, MIN_CHUNK],
    [undefined, MIN_CHUNK],
  ])('chunkSizeFor(%s) = %s', (length, expected) => {
    expect(chunkSizeFor(length)).toBe(expected);
  });

  it("follows the transport's write length", async () => {
    expect(await new CalendarSession(new FakeCalendar({ writeLength: 100 })).chunkSize()).toBe(100);
    expect(await new CalendarSession(new FakeCalendar({ writeLength: 244 })).chunkSize()).toBe(MAX_CHUNK);
    expect(await new CalendarSession(new FakeCalendar({ writeLength: undefined })).chunkSize()).toBe(MIN_CHUNK);
  });
});

describe('pushOrder', () => {
  it.each([
    [[1, 2, 3, 4], 2, [1, 3, 4, 2]],
    [[2, 4], 4, [2, 4]],
    [[4, 1], 3, [1, 4]],
    [[1], 1, [1]],
    [[3, 1, 3, 2, 1], 1, [2, 3, 1]],
    [[], 2, []],
  ])('%j with page %i on screen -> %j', (slots, shown, order) => {
    expect(pushOrder(slots, shown)).toEqual(order);
  });
});

describe('pushPages', () => {
  const pages = (slots: number[], length = 300) => new Map(slots.map((slot) => [slot, frameOf(length, slot)]));

  it.each([
    [2, [1, 2, 3, 4], [1, 3, 4, 2]], // page on screen goes last
    [4, [2, 4], [2, 4]],
    [3, [4, 1], [1, 4]], // page on screen not among them: ascending
    [1, [1], [1]],
  ])('with page %i on screen uploads %j as %j', async (shown, slots, order) => {
    const { calendar, session } = await started({ shown });
    const results = await settle(session.pushPages(pages(slots)));
    expect(calendar.headerSlots).toEqual(order);
    expect(results).toEqual(new Map(slots.map((slot) => [slot, 'ok'])));
  });

  it('reports progress per page and the refresh', async () => {
    const { session } = await started({ shown: 2 });
    const events: PushEvent[] = [];
    await settle(session.pushPages(pages([1, 2], 500), { onEvent: (event) => events.push(event) }));
    expect(events.filter((e) => e.phase !== 'sending').map((e) => [e.slot, e.phase])).toEqual([
      [1, 'start'],
      [1, 'done'],
      [2, 'start'],
      [2, 'done'],
      [2, 'refreshing'],
    ]);
    const sending = events.filter((e) => e.phase === 'sending');
    expect(sending.length).toBeGreaterThan(0);
    expect(sending.at(-1)).toMatchObject({ sent: 500, total: 500 });
    expect(new Set(events.map((e) => e.count))).toEqual(new Set([2]));
    expect(events.filter((e) => e.phase === 'start').map((e) => e.index)).toEqual([0, 1]);
    expect(session.refreshing).toBe(true);
  });

  it('reports unchanged pages and no refresh for them', async () => {
    const { calendar, session } = await started({ shown: 1, headerReply: [...RSP_HEADER_SAME_IMAGE] });
    const events: PushEvent[] = [];
    const results = await settle(session.pushPages(pages([1, 2]), { onEvent: (event) => events.push(event) }));
    expect(results).toEqual(new Map([[2, 'unchanged'], [1, 'unchanged']]));
    expect(events.map((e) => e.phase)).toEqual(['start', 'unchanged', 'start', 'unchanged']);
    expect(calendar.imageWrites()).toEqual([]);
    expect(session.refreshing).toBe(false);
  });

  it('retries the status query while the calendar is refreshing', async () => {
    const { calendar, session } = await started({ shown: 2, refreshMs: 10_000 }, {});
    await settle(session.pushPages(pages([2])));
    expect(calendar.refreshing).toBe(true);
    const before = Date.now();
    const results = await settle(session.pushPages(pages([1, 2], 301)));
    expect(Date.now() - before).toBeGreaterThanOrEqual(10_000);
    expect(results).toEqual(new Map([[1, 'ok'], [2, 'ok']]));
    expect(calendar.headerSlots).toEqual([2, 1, 2]);
  });

  it('stops at the first failing page, naming it and keeping earlier results', async () => {
    const { calendar, session } = await started({ shown: 4, failSlots: [2] });
    const error = await failure(session.pushPages(pages([1, 2, 3, 4])));
    expect(error).toBeInstanceOf(PushFailed);
    const failed = error as PushFailed;
    expect(failed.slot).toBe(2);
    expect(failed.completed).toEqual(new Map([[1, 'ok']]));
    expect(failed.message).toBe('page 2: the device rejected the image (02 01)');
    expect(failed.cause).toBeInstanceOf(UploadFailed);
    expect(calendar.headerSlots).toEqual([1, 2]); // pages 3 and 4 were not sent
  });

  it('stops when the link drops in the middle of a page', async () => {
    // Page 1 takes 2 packets of 244 bytes (300 bytes); the link drops during page 2.
    const { calendar, session } = await started({ shown: 4, dropAfterPackets: 3 });
    const error = await failure(session.pushPages(pages([1, 2, 3])));
    expect(error).toBeInstanceOf(PushFailed);
    const failed = error as PushFailed;
    expect(failed.slot).toBe(2);
    expect(failed.completed).toEqual(new Map([[1, 'ok']]));
    expect(failed.cause).toBeInstanceOf(TransportError);
    expect((failed.cause as TransportError).code).toBe('linkLost');
    expect(calendar.headerSlots).toEqual([1, 2]);
  });

  it('wraps a page that stays busy in PushFailed', async () => {
    const { session } = await started({ shown: 1, headerReply: [...RSP_HEADER_BUSY] });
    const error = await failure(session.pushPages(pages([3]), { busyTimeoutMs: 100 }));
    expect(error).toBeInstanceOf(PushFailed);
    expect((error as PushFailed).cause).toBeInstanceOf(DeviceBusy);
    expect((error as Error).message).toMatch(/^page 3: the device did not accept an image for page 3/);
  });

  it('rejects pages outside 1-4 before sending anything', async () => {
    const { calendar, session } = await started();
    const writes = calendar.writes.length;
    await expect(session.pushPages(pages([2, 5]))).rejects.toBeInstanceOf(RangeError);
    await expect(session.pushPages(pages([0]))).rejects.toThrow(/pages are 1-4, got 0/);
    expect(calendar.writes).toHaveLength(writes);
  });

  it('pushes a full frame', async () => {
    const { calendar, session } = await started({ shown: 1, writeLength: 180 });
    const results = await settle(session.pushPages(new Map([[1, frameOf(FRAME_BYTES)]])));
    expect(results.get(1)).toBe('ok');
    expect(calendar.received).toBe(FRAME_BYTES);
    expect(calendar.packets).toBe(Math.ceil(FRAME_BYTES / 180));
  });
});

describe('goodbye', () => {
  it('is skipped while the panel refreshes', async () => {
    const { calendar, session } = await started({ shown: 2, refreshMs: 40_000 }, { ...QUICK, replyTimeoutMs: 1_000 });
    await settle(session.pushPages(new Map([[1, frameOf(100)], [2, frameOf(100)]])));
    const before = Date.now();
    await settle(session.goodbye());
    expect(Date.now() - before).toBe(0); // no wait for an answer that cannot come
    expect(calendar.commands().map(hex)).not.toContain(hex(CMD_DISCONNECT));
  });

  it('is sent when the panel is not refreshing', async () => {
    const { calendar, session } = await started({ shown: 2, refreshMs: 40_000 });
    await settle(session.pushPages(new Map([[1, frameOf(100)]]))); // page 2 stays on screen
    await settle(session.goodbye());
    expect(calendar.commands().map(hex)).toContain(hex(CMD_DISCONNECT));
  });

  it('never rejects, on a dead link or a failing one', async () => {
    const { calendar, session } = await started();
    calendar.failWrites = new TransportError('linkLost', 'gone');
    await expect(settle(session.goodbye())).resolves.toBeUndefined();
    calendar.failWrites = undefined;
    calendar.drop();
    await expect(settle(session.goodbye())).resolves.toBeUndefined();
    expect(calendar.connectCalls).toBe(1); // no reconnect just to say goodbye
  });

  it('close says goodbye and disconnects', async () => {
    const { calendar, session } = await started();
    await settle(session.close());
    expect(calendar.commands().map(hex)).toContain(hex(CMD_DISCONNECT));
    expect(calendar.connected).toBe(false);
  });

  it('after close, the next operation reconnects and unlocks before the header', async () => {
    const { calendar, session } = await started();
    await settle(session.close());
    const writesBefore = calendar.writes.length;
    const frame = frameOf(100);
    expect(await settle(session.upload(frame, 1))).toBe('ok');
    expect(calendar.connectCalls).toBe(2);
    const commands = calendar.writes.slice(writesBefore).filter((w) => w.characteristic === 'command');
    // ready() unlocks the new link; upload() unlocks again right before its header.
    expect(commands.map((w) => hex(w.data))).toEqual([hex(CMD_UNLOCK), hex(CMD_UNLOCK), hex(buildImageHeader(frame, 1))]);
  });
});

describe('link loss', () => {
  it('fails a pending command at once instead of waiting for the timeout', async () => {
    const { calendar, session } = await started({ silent: [OP_BATTERY] }, { replyTimeoutMs: 5_000 });
    const outcome = session.battery().catch((error: unknown) => error);
    await vi.advanceTimersByTimeAsync(10);
    const before = Date.now();
    calendar.drop();
    const error = await outcome;
    expect(error).toBeInstanceOf(TransportError);
    expect((error as TransportError).code).toBe('linkLost');
    expect((error as Error).message).toBe('the device disconnected');
    expect(Date.now() - before).toBe(0);
  });

  it('reconnects and unlocks again on the next call', async () => {
    const { calendar, session } = await started();
    calendar.drop();
    const writesBefore = calendar.writes.length;
    expect((await settle(session.battery())).level).toBe(4);
    expect(calendar.connectCalls).toBe(2);
    expect(calendar.writes.slice(writesBefore).map((w) => hex(w.data))).toEqual([hex(CMD_UNLOCK), hex(CMD_BATTERY)]);
  });

  it('reconnects with attempts like connectSession, then reports what failed', async () => {
    const { calendar, session } = await started({}, { ...QUICK, attempts: 2, retryDelayMs: 10, connectWindowMs: 0 });
    calendar.drop();
    calendar.connectFailures.push(
      new TransportError('notFound', 'no device found'),
      new TransportError('notFound', 'no device found'),
    );
    const error = await failure(session.currentSlot());
    expect(error).toBeInstanceOf(ConnectFailed);
    expect((error as ConnectFailed).attempts).toBe(2);
    expect(((error as Error).cause as TransportError).code).toBe('notFound');
    expect(calendar.connectOptions.slice(1).map((options) => options?.timeoutMs)).toEqual([15_000, 15_000]);
    expect(calendar.commands().map(hex)).not.toContain(hex(CMD_GET_SLOT));
  });

  it('waits until the panel refresh should be over before reconnecting, and says until when', async () => {
    const events: LinkEvent[] = [];
    const { calendar, session } = await started({}, { ...QUICK, onLink: (event) => events.push(event) });
    await settle(session.show(2));
    const shownAt = Date.now();
    await vi.advanceTimersByTimeAsync(20_000);
    calendar.drop(); // as the device does 14-25 s into a refresh
    expect((await settle(session.battery())).level).toBe(4);
    expect(events[0]).toEqual({ type: 'waiting', until: shownAt + 45_000 });
    expect(events.slice(1)).toEqual([
      { type: 'attempt', attempt: 1 },
      { type: 'connected', attempt: 1 },
    ]);
    expect(calendar.connectTimes[1]).toBe(shownAt + 45_000);
  });

  it('reconnects at once when the refresh started long enough ago', async () => {
    const events: LinkEvent[] = [];
    const { calendar, session } = await started({}, { ...QUICK, onLink: (event) => events.push(event) });
    await settle(session.show(2));
    await vi.advanceTimersByTimeAsync(50_000);
    calendar.drop();
    const droppedAt = Date.now();
    await settle(session.battery());
    expect(calendar.connectTimes[1]).toBe(droppedAt);
    expect(events.map((event) => event.type)).toEqual(['attempt', 'connected']);
  });

  it('reconnects at once when the device answered after the refresh started', async () => {
    const { calendar, session } = await started();
    await settle(session.show(2));
    await settle(session.battery()); // answered: the refresh is over
    calendar.drop();
    const droppedAt = Date.now();
    await settle(session.battery());
    expect(calendar.connectTimes[1]).toBe(droppedAt);
  });

  it('stops waiting for the refresh when the signal aborts', async () => {
    const { calendar, session } = await started();
    await settle(session.show(2));
    calendar.drop();
    const controller = new AbortController();
    const outcome = session.start(controller.signal).catch((error: unknown) => error);
    await vi.advanceTimersByTimeAsync(10_000);
    controller.abort();
    const error = await outcome;
    expect(error).toBeInstanceOf(TransportError);
    expect((error as TransportError).code).toBe('cancelled');
    expect(calendar.connectCalls).toBe(1);
  });

  it('rides out the drop during a refresh before the header: reconnects after the refresh, then uploads', async () => {
    // Switch the page, send at once: the device answers nothing, then drops
    // the link ~20 s into its refresh, as it does (default timing).
    const events: LinkEvent[] = [];
    const { calendar, session } = await started({ refreshMs: 40_000 }, { onLink: (event) => events.push(event) });
    await settle(session.show(2));
    const shownAt = Date.now();
    const upload = session.upload(frameOf(300), 1);
    upload.catch(() => undefined);
    await vi.advanceTimersByTimeAsync(20_000);
    calendar.drop();
    expect(await settle(upload)).toBe('ok');
    expect(calendar.connectTimes[1]).toBe(shownAt + 45_000);
    expect(events).toEqual([
      { type: 'waiting', until: shownAt + 45_000 },
      { type: 'attempt', attempt: 1 },
      { type: 'connected', attempt: 1 },
    ]);
    expect(calendar.headerSlots).toEqual([1]);
    expect(calendar.received).toBe(300);
  });

  it('does not reconnect inside an upload for a drop outside a refresh', async () => {
    const { calendar, session } = await started({ silentHeaders: 10_000 }, { replyTimeoutMs: 1_000 });
    const upload = session.upload(frameOf(300), 1);
    upload.catch(() => undefined);
    await vi.advanceTimersByTimeAsync(2_500);
    calendar.drop();
    const error = await failure(upload);
    expect((error as TransportError).code).toBe('linkLost');
    expect(calendar.connectCalls).toBe(1);
  });
});

describe('stopping', () => {
  /** How `promise` settled so far: undefined while pending, else `{ value }` or `{ error }`. */
  function watch<T>(promise: Promise<T>): () => { value: T } | { error: unknown } | undefined {
    let outcome: { value: T } | { error: unknown } | undefined;
    promise.then(
      (value) => {
        outcome = { value };
      },
      (error: unknown) => {
        outcome = { error };
      },
    );
    return () => outcome;
  }

  it('stops an upload at once while it waits its turn behind a reconnect', async () => {
    const { calendar, session } = await started();
    await settle(session.show(2));
    await vi.advanceTimersByTimeAsync(20_000);
    calendar.drop();
    const reconnect = session.start(); // like the page's own reconnect: waits for the refresh to end
    const controller = new AbortController();
    const upload = watch(session.upload(frameOf(100), 1, { signal: controller.signal }));
    await vi.advanceTimersByTimeAsync(1_000);
    expect(upload()).toBeUndefined();
    controller.abort();
    await vi.advanceTimersByTimeAsync(0);
    const outcome = upload();
    expect(outcome && 'error' in outcome && (outcome.error as Error).name).toBe('AbortError');
    await settle(reconnect);
    // The upload never started, not even after the reconnect.
    expect(calendar.commandsWith(OP_IMAGE_HEADER)).toHaveLength(0);
  });

  it('stops an upload that is reconnecting with the signal’s reason, not as a cancelled connect', async () => {
    const { calendar, session } = await started();
    await settle(session.show(2));
    calendar.drop();
    const controller = new AbortController();
    const upload = watch(session.upload(frameOf(100), 1, { signal: controller.signal }));
    await vi.advanceTimersByTimeAsync(10_000); // waiting for the refresh before reconnecting
    controller.abort();
    await vi.advanceTimersByTimeAsync(0);
    const outcome = upload();
    expect(outcome && 'error' in outcome && (outcome.error as Error).name).toBe('AbortError');
    expect(calendar.connectCalls).toBe(1);
  });

  it('stops a start at once while it waits its turn, as a cancelled connect', async () => {
    const { calendar, session } = await started({ silent: [OP_BATTERY] }, { replyTimeoutMs: 5_000 });
    const battery = session.battery();
    battery.catch(() => undefined);
    const controller = new AbortController();
    const start = watch(session.start(controller.signal));
    await vi.advanceTimersByTimeAsync(1_000);
    controller.abort();
    await vi.advanceTimersByTimeAsync(0);
    const outcome = start();
    expect(outcome && 'error' in outcome && (outcome.error as TransportError).code).toBe('cancelled');
    await failure(battery);
    expect(calendar.commandsWith(OP_UNLOCK)).toHaveLength(1); // the stopped start never unlocked
  });
});

describe('panel refresh', () => {
  it('remembers when switching the page started a refresh', async () => {
    const { session } = await started();
    expect(session.refreshStartedAt).toBeUndefined();
    await vi.advanceTimersByTimeAsync(1_000);
    await settle(session.show(2));
    expect(session.refreshing).toBe(true);
    expect(session.refreshStartedAt).toBe(Date.now());
  });

  it('remembers when replacing the page on screen started a refresh, and keeps the time after it', async () => {
    const { session } = await started({ shown: 2 });
    await settle(session.currentSlot());
    await settle(session.upload(frameOf(100), 1));
    expect(session.refreshStartedAt).toBeUndefined(); // page 1 is not on screen
    await settle(session.upload(frameOf(100), 2));
    const startedAt = Date.now();
    expect(session.refreshing).toBe(true);
    expect(session.refreshStartedAt).toBe(startedAt);
    await vi.advanceTimersByTimeAsync(5_000);
    await settle(session.battery()); // the device answers again
    expect(session.refreshing).toBe(false);
    expect(session.refreshStartedAt).toBe(startedAt);
  });
});

describe('connectSession', () => {
  it('connects, unlocks and passes the attempt timeout and signal to the transport', async () => {
    const calendar = new FakeCalendar();
    const controller = new AbortController();
    const session = await settle(
      connectSession(calendar, { attemptTimeoutMs: 1234, signal: controller.signal, ...QUICK }),
    );
    expect(session).toBeInstanceOf(CalendarSession);
    expect(calendar.connectOptions).toEqual([{ timeoutMs: 1234, signal: controller.signal }]);
    expect(calendar.commands().map(hex)).toEqual([hex(CMD_UNLOCK)]);
    expect(session.options.replyTimeoutMs).toBe(50);
  });

  it('gives each attempt about 15 s by default', async () => {
    const calendar = new FakeCalendar();
    await settle(connectSession(calendar, QUICK));
    expect(calendar.connectOptions[0]?.timeoutMs).toBe(15_000);
  });

  it('keeps making 15 s attempts for about 90 s while the device does not answer', async () => {
    const calendar = new FakeCalendar();
    const starts: number[] = [];
    calendar.connect = async (options?: ConnectOptions) => {
      starts.push(Date.now());
      await new Promise((resolve) => setTimeout(resolve, options?.timeoutMs ?? 0));
      throw new TransportError('timeout', 'connecting took longer than 15 s');
    };
    const before = Date.now();
    const error = await failure(connectSession(calendar, QUICK));
    expect(error).toBeInstanceOf(ConnectFailed);
    // 15 s attempts, 5 s apart; none starts later than 90 s after the first.
    expect(starts.map((time) => time - before)).toEqual([0, 20_000, 40_000, 60_000, 80_000]);
    expect((error as ConnectFailed).attempts).toBe(5);
    expect((error as ConnectFailed).droppedWhileConnecting).toBe(false);
  });

  it('does not add attempts for a device that drops the link while connecting, and says why', async () => {
    const calendar = new FakeCalendar();
    const drop = () => new TransportError('linkLost', 'the device disconnected', { droppedWhileConnecting: true });
    calendar.connectFailures.push(drop(), drop(), drop(), drop(), drop());
    const error = await failure(connectSession(calendar, QUICK));
    expect(calendar.connectCalls).toBe(4); // the default number of attempts
    expect(error).toBeInstanceOf(ConnectFailed);
    expect((error as ConnectFailed).droppedWhileConnecting).toBe(true);
    expect((error as ConnectFailed).stalePairing).toBe(false);
    expect((error as Error).message).toBe(
      `could not connect after 4 attempts: the device disconnected; the device dropped the link while connecting: ${PAIRING_MODE_STEPS}`,
    );
  });

  it('reports each attempt, and a drop while connecting as soon as it happens', async () => {
    const calendar = new FakeCalendar();
    const dropped = new TransportError('linkLost', 'the device disconnected', { droppedWhileConnecting: true });
    const slow = new TransportError('timeout', 'connecting took longer than 15 s');
    calendar.connectFailures.push(dropped, slow);
    const events: LinkEvent[] = [];
    await settle(connectSession(calendar, { ...QUICK, retryDelayMs: 10, onLink: (event) => events.push(event) }));
    expect(events).toEqual([
      { type: 'attempt', attempt: 1 },
      { type: 'failed', attempt: 1, error: dropped, droppedWhileConnecting: true },
      { type: 'attempt', attempt: 2 },
      { type: 'failed', attempt: 2, error: slow, droppedWhileConnecting: false },
      { type: 'attempt', attempt: 3 },
      { type: 'connected', attempt: 3 },
    ]);
  });

  it('ends with a gaveUp event, and ignores a listener that throws', async () => {
    const calendar = new FakeCalendar();
    calendar.connectFailures.push(new TransportError('cancelled', 'chooser closed'));
    const events: LinkEvent[] = [];
    const error = await failure(
      connectSession(calendar, {
        ...QUICK,
        onLink: (event) => {
          events.push(event);
          throw new Error('broken listener');
        },
      }),
    );
    expect((error as TransportError).code).toBe('cancelled');
    expect(events.map((event) => event.type)).toEqual(['attempt', 'gaveUp']);
    expect(events.at(-1)).toEqual({ type: 'gaveUp', error });
  });

  it('retries link drops, timeouts and a silent unlock, disconnecting after each failure', async () => {
    const calendar = new FakeCalendar({ silentUnlocks: 1 });
    calendar.connectFailures.push(
      new TransportError('notFound', 'not advertising'),
      new TransportError('timeout', 'connect timed out'),
    );
    const before = Date.now();
    const session = await settle(connectSession(calendar, { ...QUICK, attempts: 4 }));
    expect((await settle(session.battery())).level).toBe(4);
    expect(calendar.connectCalls).toBe(4);
    expect(calendar.disconnectCalls).toBe(3);
    expect(Date.now() - before).toBeGreaterThanOrEqual(3 * 5_000); // default retry delay
  });

  it('gives up after the last attempt', async () => {
    const calendar = new FakeCalendar();
    calendar.connectFailures.push(new TransportError('timeout', 'first'), new TransportError('timeout', 'second'));
    const error = await failure(connectSession(calendar, { attempts: 2, retryDelayMs: 0, connectWindowMs: 0 }));
    expect(error).toBeInstanceOf(DeviceError);
    expect((error as Error).message).toBe('could not connect after 2 attempts: second');
    expect((error as Error).cause).toBeInstanceOf(TransportError);
    expect(calendar.disconnectCalls).toBe(2);
  });

  it('suggests pairing again when every attempt dropped while notifications were enabled', async () => {
    const calendar = new FakeCalendar();
    const drop = () => new TransportError('linkLost', 'the device disconnected', { duringPairing: true });
    calendar.connectFailures.push(drop(), drop(), drop());
    const error = await failure(connectSession(calendar, { attempts: 3, retryDelayMs: 0 }));
    expect(error).toBeInstanceOf(ConnectFailed);
    expect(error).toBeInstanceOf(DeviceError);
    expect((error as ConnectFailed).stalePairing).toBe(true);
    expect((error as ConnectFailed).attempts).toBe(3);
    expect((error as Error).message).toMatch(
      /^could not connect after 3 attempts: the device disconnected; .*stale pairing: forget the device/,
    );
  });

  it('does not suggest pairing again when some attempt failed otherwise', async () => {
    const calendar = new FakeCalendar();
    calendar.connectFailures.push(
      new TransportError('linkLost', 'the device disconnected', { duringPairing: true }),
      new TransportError('notFound', 'not advertising'),
    );
    const error = await failure(connectSession(calendar, { attempts: 2, retryDelayMs: 0, connectWindowMs: 0 }));
    expect((error as ConnectFailed).stalePairing).toBe(false);
    // The drop still points at pairing mode, but nobody is sent to forget the device.
    expect((error as ConnectFailed).droppedWhileConnecting).toBe(true);
    expect((error as Error).message).toBe(
      `could not connect after 2 attempts: not advertising; the device dropped the link while connecting: ${PAIRING_MODE_STEPS}`,
    );
    expect((error as Error).message).not.toMatch(/forget/);
  });

  it('throws what only the user can fix at once', async () => {
    const calendar = new FakeCalendar();
    calendar.connectFailures.push(new TransportError('cancelled', 'chooser closed'));
    const error = await failure(connectSession(calendar, { retryDelayMs: 0 }));
    expect((error as TransportError).code).toBe('cancelled');
    expect(calendar.connectCalls).toBe(1);
  });

  it('does not retry programming errors', async () => {
    const calendar = new FakeCalendar();
    calendar.connect = async () => {
      throw new TypeError('bug');
    };
    await expect(settle(connectSession(calendar, { retryDelayMs: 0 }))).rejects.toBeInstanceOf(TypeError);
  });

  it('stops waiting between attempts when the signal aborts', async () => {
    const calendar = new FakeCalendar();
    calendar.connectFailures.push(new TransportError('notFound', 'not advertising'));
    const controller = new AbortController();
    const outcome = connectSession(calendar, { signal: controller.signal }).catch((error: unknown) => error);
    await vi.advanceTimersByTimeAsync(1_000);
    controller.abort();
    const error = await outcome;
    expect((error as TransportError).code).toBe('cancelled');
    expect(calendar.connectCalls).toBe(1);
  });
});

describe('diagnostics log', () => {
  it('logs with timestamps and never a whole frame', async () => {
    const entries: LogEntry[] = [];
    const { session } = await started({ shown: 1, writeLength: 180 }, { ...QUICK, log: (entry) => entries.push(entry) });
    await settle(session.pushPages(new Map([[2, frameOf(FRAME_BYTES)]])));
    expect(entries.length).toBeGreaterThan(0);
    expect(entries.every((e) => typeof e.time === 'number' && e.source === 'session')).toBe(true);
    expect(entries.some((e) => e.message.startsWith(`page 2: stored ${FRAME_BYTES} bytes`))).toBe(true);
    expect(Math.max(...entries.map((e) => e.message.length))).toBeLessThan(160);
  });

  it('describes each frame before its header: CRC-32 and the bands of 60 rows that are all white', async () => {
    const entries: LogEntry[] = [];
    const { session } = await started({ shown: 1 }, { ...QUICK, log: (entry) => entries.push(entry) });
    const frame = new Uint8Array(FRAME_BYTES).fill(0x11);
    frame.fill(0x23, 355 * 400); // white down to row 354
    await settle(session.pushPages(new Map([[2, frame]])));
    const crc = crc32(frame).toString(16).padStart(8, '0');
    const described = entries.findIndex(
      (e) => e.message === `page 2: frame of ${FRAME_BYTES} bytes, crc32 ${crc}, all-white 60-row bands WWWWW...`,
    );
    expect(described).toBeGreaterThanOrEqual(0);
    expect(entries.findIndex((e) => e.message.startsWith('> 01 '))).toBeGreaterThan(described);
  });

  it('survives a logger that throws', async () => {
    const { session } = await started({}, {
      ...QUICK,
      log: () => {
        throw new Error('broken logger');
      },
    });
    expect((await settle(session.battery())).level).toBe(4);
  });
});
