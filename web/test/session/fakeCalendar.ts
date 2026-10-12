/**
 * A scripted calendar on top of FakeTransport: answers commands the way the
 * device does, collects image data and reports the upload's result, and can
 * misbehave on request (stay silent, answer busy, refresh for a while after
 * the page on screen was replaced, give up mid-upload, drop the link).
 *
 * Timing uses setTimeout and Date.now(), so tests with fake timers can play
 * out the calendar's ~40 s refresh in no time.
 */

import { vi } from 'vitest';
import { type ConnectOptions, type ProtocolCharacteristic, TransportError } from '../../src/ble/transport';
import {
  bytesEqual,
  OP_BATTERY,
  OP_DEVICE_INFO,
  OP_DISCONNECT,
  OP_GET_SLOT,
  OP_IMAGE_HEADER,
  OP_SHOW_SLOT,
  OP_UNLOCK,
  RSP_DATA_FAIL,
  RSP_DATA_OK,
  RSP_HEADER_BUSY,
  RSP_HEADER_OK,
  RSP_SHOW_SLOT_OK,
  RSP_UNLOCK_OK,
} from '../../src/core/protocol';
import { FakeTransport, type RecordedWrite } from '../fakeTransport';

export interface CalendarScript {
  /** Reply to an image header. Default `01 00`. */
  readonly headerReply?: readonly number[];
  /** Result once all data arrived; null: never answer. Default `02 00`. */
  readonly dataReply?: readonly number[] | null;
  /** Opcodes the calendar ignores. */
  readonly silent?: Iterable<number>;
  /** Ignore this many unlocks first. */
  readonly silentUnlocks?: number;
  /**
   * Skip the reply to the first N commands with each opcode, sending only
   * `stray` (if any) instead, as the device was seen to do right after unlock.
   */
  readonly skipReplies?: Readonly<Record<number, number>>;
  /** Ignore this many image headers first (the panel is refreshing). */
  readonly silentHeaders?: number;
  /** Answer this many image headers with `01 01` (busy) first. */
  readonly busyHeaders?: number;
  /** Unrelated notification sent on the same characteristic just before each real reply. */
  readonly stray?: readonly number[];
  /** Report `02 01` after this many image packets (the calendar gave up early). */
  readonly failAfterPackets?: number;
  /** Drop the link after this many image packets. */
  readonly dropAfterPackets?: number;
  /** Answer `02 01` for the data of these pages. */
  readonly failSlots?: Iterable<number>;
  /** Page on screen, reported by `0C`. Default 3. */
  readonly shown?: number;
  /** After the page on screen was replaced or switched, ignore every command this long. Default 0. */
  readonly refreshMs?: number;
  /** Deliver replies this many ms later (setTimeout); default: synchronously, inside write(). */
  readonly replyDelayMs?: number;
  /** What maxWriteLength() reports. Default 244. */
  readonly writeLength?: number | undefined;
  /** Battery level reported by `06`. Default 4. */
  readonly battery?: number;
}

const text = new TextEncoder();

export class FakeCalendar extends FakeTransport {
  /** `w` per image write and `r` per read, in order. */
  readonly log: string[] = [];
  /** Slots of the headers answered `01 00`, in order. */
  readonly headerSlots: number[] = [];
  /** Options passed to each connect(). */
  readonly connectOptions: (ConnectOptions | undefined)[] = [];
  /** Date.now() at each connect() call. */
  readonly connectTimes: number[] = [];
  disconnectCalls = 0;
  packets = 0;
  received = 0;
  shown: number;
  /** When set, every write fails with it (a link that is dead but not yet reported). */
  failWrites: TransportError | undefined;

  private readonly script: CalendarScript;
  private readonly silent: Set<number>;
  private readonly failSlots: Set<number>;
  private silentUnlocks: number;
  private readonly skipReplies: Map<number, number>;
  private silentHeaders: number;
  private busyHeaders: number;
  private expected = 0;
  private currentSlot: number | undefined;
  private refreshUntil = Number.NEGATIVE_INFINITY;

  constructor(script: CalendarScript = {}) {
    super();
    this.script = script;
    this.silent = new Set(script.silent ?? []);
    this.failSlots = new Set(script.failSlots ?? []);
    this.silentUnlocks = script.silentUnlocks ?? 0;
    this.skipReplies = new Map(Object.entries(script.skipReplies ?? {}).map(([op, count]) => [Number(op), count]));
    this.silentHeaders = script.silentHeaders ?? 0;
    this.busyHeaders = script.busyHeaders ?? 0;
    this.shown = script.shown ?? 3;
    this.writeLength = 'writeLength' in script ? script.writeLength : 244;
    this.values.set('modelNumber', text.encode('P7320E-B'));
    this.values.set('firmwareRevision', text.encode('v1.0.09'));
    this.respond = (write) => this.answer(write);
  }

  /** Whether the panel is refreshing (ignoring commands) right now. */
  get refreshing(): boolean {
    return Date.now() < this.refreshUntil;
  }

  override async connect(options?: ConnectOptions): Promise<void> {
    this.connectOptions.push(options);
    this.connectTimes.push(Date.now());
    return super.connect();
  }

  override async disconnect(): Promise<void> {
    this.disconnectCalls++;
    return super.disconnect();
  }

  override async write(characteristic: ProtocolCharacteristic, data: Uint8Array, mode: RecordedWrite['mode']) {
    if (this.failWrites && this.connected) throw this.failWrites;
    return super.write(characteristic, data, mode);
  }

  override async read(characteristic: Parameters<FakeTransport['read']>[0]): Promise<Uint8Array> {
    this.log.push('r');
    return super.read(characteristic);
  }

  /** Writes to the command characteristic, as bytes. */
  commands(): Uint8Array[] {
    return this.writes.filter((w) => w.characteristic === 'command').map((w) => w.data);
  }

  /** Command writes with this opcode. */
  commandsWith(opcode: number): Uint8Array[] {
    return this.commands().filter((data) => data[0] === opcode);
  }

  /** Image packets, in order. */
  imageWrites(): Uint8Array[] {
    return this.writes.filter((w) => w.characteristic === 'image').map((w) => w.data);
  }

  private answer(write: RecordedWrite): void {
    if (write.characteristic === 'command') this.answerCommand(write.data);
    else this.receiveImage(write.data);
  }

  private answerCommand(data: Uint8Array): void {
    const op = data[0] ?? -1;
    if (this.silent.has(op) || this.refreshing) return;
    if (op === OP_UNLOCK && this.silentUnlocks > 0) {
      this.silentUnlocks--;
      return;
    }
    const skips = this.skipReplies.get(op) ?? 0;
    if (skips > 0) {
      this.skipReplies.set(op, skips - 1);
      if (this.script.stray) this.send('command', Uint8Array.from(this.script.stray));
      return;
    }
    if (op === OP_IMAGE_HEADER) {
      if (this.silentHeaders > 0) {
        this.silentHeaders--;
        return;
      }
      if (this.busyHeaders > 0) {
        this.busyHeaders--;
        this.send('command', RSP_HEADER_BUSY);
        return;
      }
      this.expected = new DataView(data.buffer, data.byteOffset).getUint32(1);
      this.received = 0;
      if (bytesEqual(this.headerReply(), RSP_HEADER_OK)) {
        this.currentSlot = data[5];
        this.headerSlots.push(data[5] ?? -1);
      }
    }
    if (op === OP_SHOW_SLOT) this.shown = data[1] ?? this.shown;
    const reply = this.replyTo(op);
    if (!reply) return;
    if (this.script.stray) this.send('command', Uint8Array.from(this.script.stray));
    this.send('command', reply);
    // Like replacing the page on screen, switching it redraws the panel.
    if (op === OP_SHOW_SLOT) this.refreshUntil = Date.now() + (this.script.refreshMs ?? 0);
  }

  private replyTo(op: number): Uint8Array | undefined {
    switch (op) {
      case OP_UNLOCK:
        return RSP_UNLOCK_OK;
      case OP_BATTERY:
        return Uint8Array.of(OP_BATTERY, this.script.battery ?? 4);
      case OP_GET_SLOT:
        return Uint8Array.of(OP_GET_SLOT, this.shown, 0xde, 0xad, 0xbe, 0xef);
      case OP_DEVICE_INFO:
        return Uint8Array.from([OP_DEVICE_INFO, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, ...text.encode('SERIAL')]);
      case OP_DISCONNECT:
        return Uint8Array.of(OP_DISCONNECT, 0x00);
      case OP_SHOW_SLOT:
        return RSP_SHOW_SLOT_OK;
      case OP_IMAGE_HEADER:
        return this.headerReply();
      default:
        return undefined;
    }
  }

  private headerReply(): Uint8Array {
    return Uint8Array.from(this.script.headerReply ?? RSP_HEADER_OK);
  }

  private receiveImage(data: Uint8Array): void {
    this.log.push('w');
    this.packets++;
    this.received += data.length;
    if (this.packets === this.script.dropAfterPackets) {
      this.drop();
      return;
    }
    if (this.packets === this.script.failAfterPackets) {
      this.send('image', RSP_DATA_FAIL);
      return;
    }
    if (this.received !== this.expected) return;
    const failed = this.currentSlot !== undefined && this.failSlots.has(this.currentSlot);
    const result = failed ? RSP_DATA_FAIL : this.script.dataReply === null ? undefined : this.dataReply();
    if (!result) return;
    if (this.script.stray) this.send('image', Uint8Array.from(this.script.stray));
    this.send('image', result);
    if (bytesEqual(result, RSP_DATA_OK) && this.currentSlot === this.shown) {
      this.refreshUntil = Date.now() + (this.script.refreshMs ?? 0);
    }
  }

  private dataReply(): Uint8Array {
    return Uint8Array.from(this.script.dataReply ?? RSP_DATA_OK);
  }

  private send(characteristic: ProtocolCharacteristic, value: Uint8Array): void {
    const delay = this.script.replyDelayMs;
    if (delay === undefined) this.notify(characteristic, value);
    else setTimeout(() => this.notify(characteristic, value), delay);
  }
}

/**
 * Await `promise` while running fake timers, one timer at a time, so that
 * timeouts, retries and the calendar's refresh play out instantly. Rejections
 * come back as rejections.
 */
export async function settle<T>(promise: Promise<T>, maxTimers = 10_000): Promise<T> {
  let done = false;
  const outcome = promise.then(
    (value) => {
      done = true;
      return { ok: true as const, value };
    },
    (error: unknown) => {
      done = true;
      return { ok: false as const, error };
    },
  );
  for (let i = 0; !done && i < maxTimers; i++) await vi.advanceTimersToNextTimerAsync();
  if (!done) throw new Error(`still pending after ${maxTimers} timers`);
  const result = await outcome;
  if (!result.ok) throw result.error;
  return result.value;
}

/** The error `promise` rejects with (fails the test when it resolves). */
export async function failure(promise: Promise<unknown>): Promise<unknown> {
  try {
    await settle(promise);
  } catch (error) {
    return error;
  }
  throw new Error('expected a rejection');
}

/** `length` bytes of a recognisable pattern. */
export function frameOf(length: number, seed = 0): Uint8Array {
  return Uint8Array.from({ length }, (_, i) => (i * 7 + seed) & 0xff);
}
