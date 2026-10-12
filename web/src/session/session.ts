/**
 * A protocol session with one calendar on top of a Transport.
 *
 * Commands go to the command characteristic; replies come back as
 * notifications and are matched by opcode (stale replies are dropped before
 * each command, unrelated ones while waiting). Uploads stream the frame to
 * the image characteristic and wait for its `02 xx` result.
 *
 * Behaviour the device imposes:
 * - Uploads need `unlock` first (start() unlocks; upload() unlocks again
 *   before each header).
 * - Replacing or switching the page on screen makes the panel refresh for
 *   ~40 s, during which the device answers nothing at all and usually drops
 *   the link 15-25 s in. Headers and status queries are therefore retried
 *   every `busyRetryDelayMs` until `busyTimeoutMs`, pushPages uploads the
 *   page on screen last, and a reconnect waits until `refreshWaitMs` after
 *   the refresh started before its first attempt. An upload or push whose
 *   link the device drops meanwhile reconnects then and goes on.
 * - Right after unlock the device may skip a reply; the idempotent queries
 *   (battery, page on screen, device information) are asked once more when
 *   they get no reply.
 * - Some platforms only queue writes without response and drop packets when
 *   the queue overflows; reading the firmware revision every `flushEvery`
 *   chunks keeps the queue drained. Where the firmware revision cannot be
 *   read, uploads go ahead without that barrier (and log a warning).
 *
 * Public operations run one at a time, in call order, so replies cannot get
 * mixed up. When the link drops, whatever waits on it fails at once with
 * TransportError `linkLost`; the next operation reconnects (short attempts,
 * like connectSession) and unlocks again before it starts.
 */

import {
  type Logger,
  type LogLevel,
  makeLog,
  PAIRING_MODE_STEPS,
  previewBytes,
  type ProtocolCharacteristic,
  REPAIR_STEPS,
  type Transport,
  TransportError,
  type Unsubscribe,
} from '../ble/transport';
import {
  type Battery,
  buildImageHeader,
  buildShowSlot,
  bytesEqual,
  chunks,
  CMD_BATTERY,
  CMD_DEVICE_INFO,
  CMD_DISCONNECT,
  CMD_GET_SLOT,
  CMD_UNLOCK,
  DEFAULT_MODE,
  DeviceError,
  type DeviceInfo,
  MAX_CHUNK,
  MIN_CHUNK,
  OP_IMAGE_DATA,
  parseBattery,
  parseDeviceInfo,
  parseSlot,
  ProtocolError,
  RSP_DATA_OK,
  RSP_HEADER_BUSY,
  RSP_HEADER_OK,
  RSP_HEADER_SAME_IMAGE,
  RSP_SHOW_SLOT_OK,
  RSP_UNLOCK_OK,
  type SlotStatus,
  toHex,
  USER_SLOTS,
} from '../core/protocol';

/** Outcome of uploading one page. */
export type UploadResult =
  /** Stored. */
  | 'ok'
  /** The page already held a frame with the same CRC; nothing was sent. */
  | 'unchanged';

/**
 * - `start`: about to upload `slot`.
 * - `sending`: `sent` of `total` bytes written.
 * - `done` / `unchanged`: that page finished.
 * - `refreshing`: the page on screen was replaced; the panel now refreshes
 *   for ~40 s.
 */
export type PushPhase = 'start' | 'sending' | 'done' | 'unchanged' | 'refreshing';

/** Progress of pushPages, one event per step. */
export interface PushEvent {
  readonly slot: number;
  readonly phase: PushPhase;
  /** Position of this page in the push (0-based) and the number of pages. */
  readonly index: number;
  readonly count: number;
  /** Bytes written so far and the frame size (0 where not meaningful). */
  readonly sent: number;
  readonly total: number;
}

/** Called after each chunk with the bytes written so far and the frame size. */
export type Progress = (sent: number, total: number) => void;

/**
 * Progress of connecting (connectSession) or reconnecting (the next
 * operation after the link dropped), for the page to show:
 * - `waiting`: the panel is still refreshing; the first attempt starts at
 *   `until` (a Date.now() time), so a countdown can be shown.
 * - `attempt`: attempt `attempt` starts.
 * - `failed`: attempt `attempt` failed with `error` (more may follow).
 *   `droppedWhileConnecting`: the device dropped the link before
 *   notifications were on, which a device that is not in pairing mode does
 *   to a phone it does not know: time to show the pairing-mode hint.
 * - `connected`: the link is up and unlocked.
 * - `gaveUp`: connecting ended without a link; `error` is what it throws.
 */
export type LinkEvent =
  | { readonly type: 'waiting'; readonly until: number }
  | { readonly type: 'attempt'; readonly attempt: number }
  | {
      readonly type: 'failed';
      readonly attempt: number;
      readonly error: unknown;
      readonly droppedWhileConnecting: boolean;
    }
  | { readonly type: 'connected'; readonly attempt: number }
  | { readonly type: 'gaveUp'; readonly error: unknown };

/** Timing and flow control of a session. All durations in milliseconds. */
export interface SessionOptions {
  /** Read the firmware revision every N image chunks; 0 disables it. Default 10. */
  readonly flushEvery?: number;
  /** Pause after each image chunk. Default 0. */
  readonly chunkDelayMs?: number;
  /** How long a command waits for its reply. Default 5 000. */
  readonly replyTimeoutMs?: number;
  /** How long an upload waits for the `02 xx` result after the data. Default 90 000. */
  readonly resultTimeoutMs?: number;
  /** Pause between attempts while the calendar is silent or busy. Default 3 000. */
  readonly busyRetryDelayMs?: number;
  /**
   * Connection attempts (each the whole setup: connect, notifications,
   * unlock) made before giving up on failures a retry may fix. Attempts that
   * fail without the device dropping the link (timeouts, not found, no reply
   * to unlock) go on past this number until connectWindowMs. Default 4.
   */
  readonly attempts?: number;
  /** Pause between connection attempts. Default 5 000. */
  readonly retryDelayMs?: number;
  /**
   * How long one attempt may take to bring up the link (ConnectOptions.timeoutMs;
   * a pairing prompt gets longer). Default 15 000.
   */
  readonly attemptTimeoutMs?: number;
  /**
   * Keep making attempts this long after the first one started while the
   * device does not answer (as during a panel refresh). Default 90 000.
   */
  readonly connectWindowMs?: number;
  /**
   * A reconnect waits until this long after the panel started to refresh
   * before its first attempt (the refresh takes ~40 s). Default 45 000.
   */
  readonly refreshWaitMs?: number;
  /** Progress of (re)connecting; must not throw (what it throws is ignored). */
  readonly onLink?: (event: LinkEvent) => void;
  /** Diagnostics log: commands and replies (short previews), retries, upload summaries. */
  readonly log?: Logger;
}

/** The values used where SessionOptions leaves something out. */
export const SESSION_DEFAULTS = Object.freeze({
  flushEvery: 10,
  chunkDelayMs: 0,
  replyTimeoutMs: 5_000,
  resultTimeoutMs: 90_000,
  busyRetryDelayMs: 3_000,
  attempts: 4,
  retryDelayMs: 5_000,
  attemptTimeoutMs: 15_000,
  connectWindowMs: 90_000,
  refreshWaitMs: 45_000,
});

/** Default of UploadOptions.busyTimeoutMs and PushOptions.busyTimeoutMs. */
export const DEFAULT_BUSY_TIMEOUT_MS = 60_000;

export interface UploadOptions {
  /** Header mode byte. Default DEFAULT_MODE (core/protocol.ts). */
  readonly mode?: number;
  readonly onProgress?: Progress;
  /** How long the header is retried while the calendar is silent or busy. Default 60 000. */
  readonly busyTimeoutMs?: number;
  /**
   * Stops the upload before the next chunk or retry, or while it waits for
   * the result (rejects with the signal's reason, an AbortError by default).
   */
  readonly signal?: AbortSignal;
}

export interface PushOptions {
  readonly onEvent?: (event: PushEvent) => void;
  /** Per page, see UploadOptions.busyTimeoutMs. Default 60 000. */
  readonly busyTimeoutMs?: number;
  /** Stops the push like UploadOptions.signal stops an upload; that error is not wrapped. */
  readonly signal?: AbortSignal;
}

export interface ConnectSessionOptions extends SessionOptions {
  /** Stops connecting (TransportError `cancelled`). */
  readonly signal?: AbortSignal;
}

/** A command got no reply in time (the calendar ignores commands while refreshing). */
export class NoReply extends DeviceError {
  override name = 'NoReply';
  readonly opcode: number;

  constructor(opcode: number, message: string) {
    super(message);
    this.opcode = opcode;
  }
}

/** The calendar stayed silent or busy for longer than we were willing to wait. */
export class DeviceBusy extends DeviceError {
  override name = 'DeviceBusy';
}

/** The calendar rejected an uploaded frame (`02 01`: CRC mismatch, or the data stopped). */
export class UploadFailed extends DeviceError {
  override name = 'UploadFailed';
  readonly slot: number;
  readonly reply: Uint8Array;

  constructor(slot: number, reply: Uint8Array, message: string) {
    super(message);
    this.slot = slot;
    this.reply = reply;
  }
}

/**
 * Connecting (connectSession, or a reconnect) gave up: every attempt failed
 * in a way a retry might have fixed. `cause` is the last attempt's error.
 */
export class ConnectFailed extends DeviceError {
  override name = 'ConnectFailed';
  readonly attempts: number;
  /**
   * Every attempt lost the link while notifications were being enabled (see
   * TransportError.duringPairing): the device is not in pairing mode for a
   * phone it does not know, or no longer knows this phone's pairing; only
   * pairing (again) helps.
   */
  readonly stalePairing: boolean;
  /**
   * Some attempt was dropped by the device before notifications were on (see
   * TransportError.droppedWhileConnecting): if this phone has not been
   * paired with the device yet, the device was not in pairing mode.
   */
  readonly droppedWhileConnecting: boolean;

  constructor(attempts: number, last: unknown, stalePairing: boolean, droppedWhileConnecting = stalePairing) {
    const hint = stalePairing
      ? '; the link dropped every time while notifications were being enabled: the device is not in ' +
        `pairing mode, or a stale pairing: ${REPAIR_STEPS}`
      : droppedWhileConnecting
        ? `; the device dropped the link while connecting: ${PAIRING_MODE_STEPS}`
        : '';
    super(`could not connect after ${attempts} attempts: ${describe(last)}${hint}`, { cause: last });
    this.attempts = attempts;
    this.stalePairing = stalePairing;
    this.droppedWhileConnecting = stalePairing || droppedWhileConnecting;
  }
}

/**
 * A push stopped at `slot`. `completed` holds the pages finished before it;
 * the remaining pages were not sent. `cause` is the underlying error and the
 * message starts with `page N:`.
 */
export class PushFailed extends DeviceError {
  override name = 'PushFailed';
  readonly slot: number;
  readonly completed: ReadonlyMap<number, UploadResult>;

  constructor(slot: number, completed: ReadonlyMap<number, UploadResult>, message: string, cause: unknown) {
    super(message, { cause });
    this.slot = slot;
    this.completed = completed;
  }
}

export class CalendarSession {
  readonly transport: Transport;
  /** Read at each use, so replacing it between operations takes effect (diagnostics). */
  options: SessionOptions;

  private readonly inbox = new ReplyInbox();
  private readonly log = makeLog('session', () => this.options.log);
  private routes: Unsubscribe[] | undefined;
  /** Tail of the queue that runs public operations one at a time. */
  private tail: Promise<unknown> = Promise.resolve();
  /** Page on screen, as last read with `0C` (or set with `0B`). */
  private shown: number | undefined;
  private refreshingNow = false;
  private refreshStart: number | undefined;
  /** Unlock before the next operation: nothing unlocked this link yet. */
  private needsUnlock = true;

  /** Usually made by connectSession, which also connects `transport`. */
  constructor(transport: Transport, options: SessionOptions = {}) {
    this.transport = transport;
    this.options = options;
  }

  /**
   * Whether the page on screen was just replaced or switched and the panel
   * is still refreshing (~40 s), as far as the session can tell: set when
   * an upload replaced it or show() switched it, cleared by the calendar's
   * next reply.
   */
  get refreshing(): boolean {
    return this.refreshingNow;
  }

  /** When the panel last started to refresh (a Date.now() time); kept after the refresh. */
  get refreshStartedAt(): number | undefined {
    return this.refreshStart;
  }

  /**
   * Image chunk size for the current link: the transport's maxWriteLength
   * clamped to MIN_CHUNK..MAX_CHUNK (see chunkSizeFor).
   */
  async chunkSize(): Promise<number> {
    return chunkSizeFor(await this.transport.maxWriteLength?.());
  }

  /**
   * Start routing notifications (once) and unlock; reconnects first if the
   * link is down (see ready). `signal` stops it while it waits its turn or
   * reconnects (TransportError `cancelled`).
   */
  start(signal?: AbortSignal): Promise<void> {
    return this.exclusive(
      async () => {
        this.needsUnlock = true;
        await this.ready(signal);
      },
      signal,
      () => new TransportError('cancelled', 'connecting was cancelled'),
    );
  }

  /**
   * Write a command (with response) and return the notification that answers
   * it: the next one on the command characteristic with the same opcode.
   *
   * @throws NoReply after replyTimeoutMs.
   */
  command(payload: Uint8Array): Promise<Uint8Array> {
    return this.exclusive(async () => {
      await this.ready();
      return this.send(payload);
    });
  }

  /** @throws DeviceError when the device does not answer `04 00`. */
  unlock(): Promise<void> {
    return this.start();
  }

  /** Asked once more when the first try gets no reply. */
  battery(): Promise<Battery> {
    return this.exclusive(async () => {
      await this.ready();
      return parseBattery(await this.query(CMD_BATTERY));
    });
  }

  /**
   * The page on screen and the CRC-32 of its frame; remembered for
   * pushPages. Asked once more when the first try gets no reply.
   */
  currentSlot(): Promise<SlotStatus> {
    return this.exclusive(async () => {
      await this.ready();
      const status = parseSlot(await this.query(CMD_GET_SLOT));
      this.shown = status.slot;
      return status;
    });
  }

  /** Asked once more when the first try gets no reply. */
  deviceInfo(): Promise<DeviceInfo> {
    return this.exclusive(async () => {
      await this.ready();
      return parseDeviceInfo(await this.query(CMD_DEVICE_INFO));
    });
  }

  /**
   * Switch the page on screen to `slot` (1-4). The panel then refreshes for
   * ~40 s (see refreshing).
   *
   * @throws ProtocolError when `slot` is not 1-4 (nothing is sent) or the
   * calendar does not answer `0B 00`.
   */
  show(slot: number): Promise<void> {
    return this.exclusive(async () => {
      const request = buildShowSlot(slot);
      await this.ready();
      const reply = await this.send(request);
      if (!bytesEqual(reply, RSP_SHOW_SLOT_OK)) {
        throw new ProtocolError(`show page ${slot} rejected: ${toHex(reply, ' ')}`);
      }
      this.shown = slot;
      this.refreshStarted(`page ${slot} is now on screen`);
    });
  }

  /** Model number string, e.g. `P7320E-B`. */
  model(): Promise<string> {
    return this.exclusive(async () => {
      await this.ready();
      return decodeText(await this.transport.read('modelNumber'));
    });
  }

  /** Firmware revision string, e.g. `v1.0.09`. */
  firmware(): Promise<string> {
    return this.exclusive(async () => {
      await this.ready();
      return decodeText(await this.transport.read('firmwareRevision'));
    });
  }

  /**
   * Send a packed frame (FRAME_BYTES, see core/frame.ts) to `slot`:
   * unlock + header (retried while the calendar is silent or answers busy,
   * until busyTimeoutMs), then the data in chunkSize() pieces, then wait for
   * the `02 xx` result. Streaming stops early if the calendar answers on the
   * image characteristic before all data went out (it gave up).
   *
   * When the device drops the link while its panel refreshes (before it
   * accepted the header), the upload reconnects once the refresh should be
   * over (see ready) and goes on.
   *
   * @returns `unchanged` when the slot already holds this frame (`01 02`).
   * @throws DeviceBusy, NoReply, UploadFailed, DeviceError or TransportError.
   */
  upload(frame: Uint8Array, slot: number, options: UploadOptions = {}): Promise<UploadResult> {
    return this.exclusive(async () => {
      await this.readyOrStop(options.signal);
      return this.uploadNow(frame, slot, options);
    }, options.signal);
  }

  /**
   * Upload several frames `{slot: frame}` in this connection. The page on
   * screen is read first (retried like a header), then the other pages go in
   * ascending order and the page on screen last (pushOrder), so the panel
   * refreshes once, at the end. Emits PushEvents through `onEvent`.
   *
   * @throws RangeError when a slot is not 1-4 (nothing is sent).
   * @throws PushFailed at the first page that fails; later pages are not sent.
   */
  async pushPages(
    frames: ReadonlyMap<number, Uint8Array>,
    options: PushOptions = {},
  ): Promise<Map<number, UploadResult>> {
    const bad = [...frames.keys()].filter((slot) => !USER_SLOTS.includes(slot));
    if (bad.length > 0) throw new RangeError(`pages are 1-4, got ${bad.join(', ')}`);
    return this.exclusive(() => this.pushNow(frames, options), options.signal);
  }

  /**
   * Tell the calendar we are done so it can go back to sleep. Best effort:
   * never rejects. Skipped right after the page on screen was replaced,
   * because the refreshing calendar would ignore it and cost a reply timeout,
   * and when the link is down (it does not reconnect for this).
   */
  goodbye(): Promise<void> {
    return this.exclusive(async () => {
      if (this.refreshingNow) {
        this.log('info', 'no goodbye: the panel is refreshing');
        return;
      }
      if (!this.transport.connected) return;
      await this.send(CMD_DISCONNECT);
    }).catch((error: unknown) => {
      this.log('debug', `goodbye unanswered: ${describe(error)}`);
    });
  }

  /**
   * Say goodbye (best effort), stop listening to the transport and disconnect
   * it. Never rejects. The session can still be used afterwards: the next
   * operation reconnects and unlocks, like after a dropped link.
   */
  async close(): Promise<void> {
    await this.goodbye();
    for (const unsubscribe of this.routes ?? []) unsubscribe();
    this.routes = undefined;
    await this.transport.disconnect();
    // The disconnect listener that normally does this was removed above.
    this.needsUnlock = true;
    this.inbox.close(new TransportError('linkLost', 'disconnected'));
  }

  // --- Internals (run inside exclusive) -------------------------------------------

  /**
   * Run `operation` once every earlier one settled. When `signal` aborts
   * while it still waits its turn, it never starts and the result rejects at
   * once with `stopped()` (default: the signal's reason); once started, the
   * operation itself watches the signal.
   */
  private exclusive<T>(
    operation: () => Promise<T>,
    signal?: AbortSignal,
    stopped: () => unknown = () => abortReason(signal),
  ): Promise<T> {
    let started = false;
    const run = (): Promise<T> => {
      started = true;
      if (signal?.aborted) return Promise.reject(stopped());
      return operation();
    };
    const result = this.tail.then(run, run);
    this.tail = result.then(
      () => undefined,
      () => undefined,
    );
    if (!signal) return result;
    return new Promise<T>((resolve, reject) => {
      const onAbort = () => {
        if (!started) reject(stopped());
      };
      signal.addEventListener('abort', onAbort, { once: true });
      if (signal.aborted) onAbort();
      void result.then(resolve, reject).finally(() => signal.removeEventListener('abort', onAbort));
    });
  }

  private settings() {
    const options = this.options;
    return {
      flushEvery: Math.max(0, Math.floor(options.flushEvery ?? SESSION_DEFAULTS.flushEvery)),
      chunkDelayMs: options.chunkDelayMs ?? SESSION_DEFAULTS.chunkDelayMs,
      replyTimeoutMs: options.replyTimeoutMs ?? SESSION_DEFAULTS.replyTimeoutMs,
      resultTimeoutMs: options.resultTimeoutMs ?? SESSION_DEFAULTS.resultTimeoutMs,
      busyRetryDelayMs: options.busyRetryDelayMs ?? SESSION_DEFAULTS.busyRetryDelayMs,
      refreshWaitMs: options.refreshWaitMs ?? SESSION_DEFAULTS.refreshWaitMs,
    };
  }

  /** Tell options.onLink, which must not break connecting. */
  private readonly emitLink = (event: LinkEvent): void => {
    try {
      this.options.onLink?.(event);
    } catch {
      // Ignored, like a broken logger.
    }
  };

  /** The page on screen was replaced or switched: the panel refreshes now. */
  private refreshStarted(why: string): void {
    this.refreshingNow = true;
    this.refreshStart = Date.now();
    this.log('info', `${why}: the panel refreshes now`);
  }

  /** When a reconnect may start: the expected end of a refresh the device has not answered since. */
  private refreshEnd(): number | undefined {
    if (!this.refreshingNow || this.refreshStart === undefined) return undefined;
    return this.refreshStart + this.settings().refreshWaitMs;
  }

  private route(): void {
    if (this.routes) return;
    this.routes = [
      this.transport.onNotification(({ characteristic, value }) => this.inbox.deliver(characteristic, value)),
      this.transport.onDisconnect((reason) => {
        this.needsUnlock = true;
        const message = reason === 'requested' ? 'disconnected' : 'the device disconnected';
        this.inbox.close(new TransportError('linkLost', message));
        this.log(reason === 'requested' ? 'info' : 'warn', `link down (${reason})`);
      }),
    ];
  }

  /**
   * Listen, reconnect if the link is down, and unlock if this link needs it.
   * A reconnect first waits out a panel refresh the device has not answered
   * since (see refreshWaitMs), then makes attempts like connectSession;
   * `signal` stops it (TransportError `cancelled`).
   */
  private async ready(signal?: AbortSignal): Promise<void> {
    this.route();
    if (!this.transport.connected) {
      this.log('info', 'link down; reconnecting');
      await connectWithRetries(
        this.transport,
        connectPlan(this.options, this.refreshEnd()),
        () => this.unlockNewLink(),
        this.log,
        this.emitLink,
        signal,
      );
      return;
    }
    if (this.inbox.reopen()) this.needsUnlock = true;
    if (this.needsUnlock) await this.unlockNow();
  }

  /**
   * ready() for an upload or a push, which `signal` stops like the rest of
   * it: with the signal's reason, not as a cancelled connect.
   */
  private async readyOrStop(signal: AbortSignal | undefined): Promise<void> {
    try {
      await this.ready(signal);
    } catch (error) {
      if (signal?.aborted) throw abortReason(signal);
      throw error;
    }
  }

  /**
   * Whether `error` is the link the device drops during a panel refresh (as
   * it does 15-25 s in): the link is down and the device has not answered
   * since the refresh started.
   */
  private droppedWhileRefreshing(error: unknown): boolean {
    return error instanceof TransportError && error.retryable && !this.transport.connected && this.refreshingNow;
  }

  /** The setup of a reconnect attempt, once the transport is connected. */
  private async unlockNewLink(): Promise<void> {
    this.inbox.reopen();
    this.needsUnlock = true;
    await this.unlockNow();
  }

  private async unlockNow(): Promise<void> {
    const reply = await this.send(CMD_UNLOCK);
    if (!bytesEqual(reply, RSP_UNLOCK_OK)) throw new ProtocolError(`unlock rejected: ${toHex(reply, ' ')}`);
    this.needsUnlock = false;
  }

  private async send(payload: Uint8Array): Promise<Uint8Array> {
    const opcode = payload[0];
    if (opcode === undefined) throw new ProtocolError('empty command');
    this.inbox.drain('command');
    this.log('debug', `> ${previewBytes(payload)}`);
    await this.transport.write('command', payload, 'withResponse');
    const reply = await this.inbox.next('command', opcode, this.settings().replyTimeoutMs);
    this.log('debug', `< ${previewBytes(reply)}`);
    // The calendar answers nothing while its panel refreshes.
    this.refreshingNow = false;
    return reply;
  }

  /**
   * send() for a query that may be repeated without effect: asked once more
   * when the first try gets no reply (right after unlock the device has
   * been seen to skip one). Unrelated notifications are skipped as always.
   */
  private async query(payload: Uint8Array): Promise<Uint8Array> {
    try {
      return await this.send(payload);
    } catch (error) {
      if (!(error instanceof NoReply)) throw error;
      this.log('info', `${describe(error)}; asking once more`);
      return this.send(payload);
    }
  }

  /**
   * Run `attempt` until it answers; retry while the calendar is silent
   * (NoReply) or busy (undefined), every busyRetryDelayMs, until
   * `busyTimeoutMs` has passed (DeviceBusy). When the device drops the link
   * during a panel refresh, reconnect (ready: after the refresh) and try
   * again at once on the new link; `signal` stops that too.
   */
  private async whenReady(
    what: string,
    busyTimeoutMs: number,
    signal: AbortSignal | undefined,
    attempt: () => Promise<Uint8Array | undefined>,
  ): Promise<Uint8Array> {
    const deadline = Date.now() + busyTimeoutMs;
    const { busyRetryDelayMs } = this.settings();
    for (let tries = 1; ; tries++) {
      throwIfAborted(signal);
      let reply: Uint8Array | undefined;
      try {
        reply = await attempt();
      } catch (error) {
        if (this.droppedWhileRefreshing(error)) {
          // At most once per refresh: the reconnect's unlock is answered, which ends it.
          this.log('info', `the device dropped the link while refreshing; reconnecting to send ${what}`);
          await this.readyOrStop(signal);
          continue;
        }
        if (!(error instanceof NoReply)) throw error;
      }
      if (reply) return reply;
      if (Date.now() >= deadline) {
        throw new DeviceBusy(
          `the device did not accept ${what} within ${seconds(busyTimeoutMs)} (still refreshing?); ` +
            'try again in a minute',
        );
      }
      this.log('info', `no answer to ${what} yet (try ${tries}); retrying in ${seconds(busyRetryDelayMs)}`);
      await sleep(busyRetryDelayMs, signal);
    }
  }

  private async uploadNow(frame: Uint8Array, slot: number, options: UploadOptions): Promise<UploadResult> {
    const { signal, onProgress } = options;
    const header = buildImageHeader(frame, slot, options.mode ?? DEFAULT_MODE);
    const { flushEvery, chunkDelayMs, resultTimeoutMs } = this.settings();
    // Find out before the header whether the barrier can work: once the
    // calendar accepted the header, the data must keep coming.
    let barrier = flushEvery > 0;
    if (barrier && this.transport.canRead?.('firmwareRevision') === false) {
      barrier = false;
      this.log('warn', 'the firmware revision cannot be read on this link: uploading without the flush barrier');
    }
    const reply = await this.whenReady(
      `an image for page ${slot}`,
      options.busyTimeoutMs ?? DEFAULT_BUSY_TIMEOUT_MS,
      signal,
      async () => {
        await this.unlockNow();
        const answer = await this.send(header);
        return bytesEqual(answer, RSP_HEADER_BUSY) ? undefined : answer;
      },
    );
    if (bytesEqual(reply, RSP_HEADER_SAME_IMAGE)) {
      this.log('info', `page ${slot}: already holds this image`);
      return 'unchanged';
    }
    if (!bytesEqual(reply, RSP_HEADER_OK)) {
      throw new ProtocolError(`page ${slot}: unexpected header reply: ${toHex(reply, ' ')}`);
    }

    // The calendar expects the data within ~4 s of `01 00`.
    this.inbox.drain('image');
    const size = await this.chunkSize();
    const total = frame.length;
    const started = Date.now();
    let sent = 0;
    let packets = 0;
    for (const chunk of chunks(frame, size)) {
      throwIfAborted(signal);
      if (this.inbox.has('image', OP_IMAGE_DATA)) {
        this.log('warn', `page ${slot}: the device answered after ${sent} of ${total} bytes; stopping`);
        break;
      }
      await this.transport.write('image', chunk, 'withoutResponse');
      sent += chunk.length;
      packets += 1;
      if (barrier && packets % flushEvery === 0 && sent < total) {
        try {
          await this.transport.read('firmwareRevision');
        } catch (error) {
          if (!(error instanceof TransportError) || error.code !== 'unsupported') throw error;
          // Stopping here would fail the frame for sure; without the barrier it may still get through.
          barrier = false;
          this.log('warn', `uploading the rest without the flush barrier: ${describe(error)}`);
        }
      }
      onProgress?.(sent, total);
      if (chunkDelayMs > 0) await sleep(chunkDelayMs, signal);
    }

    const result = await this.inbox.next('image', OP_IMAGE_DATA, resultTimeoutMs, signal);
    if (!bytesEqual(result, RSP_DATA_OK)) {
      throw new UploadFailed(slot, result, `page ${slot}: the device rejected the image (${toHex(result, ' ')})`);
    }
    this.log(
      'info',
      `page ${slot}: stored ${total} bytes (${packets} packets of up to ${size} bytes) in ${seconds(Date.now() - started)}`,
    );
    // The panel now refreshes for ~40 s and ignores every command.
    if (slot === this.shown) this.refreshStarted(`page ${slot} is on screen`);
    return 'ok';
  }

  private async pushNow(
    frames: ReadonlyMap<number, Uint8Array>,
    options: PushOptions,
  ): Promise<Map<number, UploadResult>> {
    const results = new Map<number, UploadResult>();
    if (frames.size === 0) return results;
    const { signal } = options;
    const busyTimeoutMs = options.busyTimeoutMs ?? DEFAULT_BUSY_TIMEOUT_MS;
    const emit = options.onEvent ?? (() => undefined);

    await this.readyOrStop(signal);
    const status = await this.whenReady('a status query', busyTimeoutMs, signal, () => this.send(CMD_GET_SLOT));
    const shown = parseSlot(status).slot;
    this.shown = shown;
    const order = pushOrder(frames.keys(), shown);
    this.log('info', `pushing pages ${order.join(', ')} (page ${shown} on screen)`);

    const count = order.length;
    for (const [index, slot] of order.entries()) {
      const frame = frames.get(slot) as Uint8Array;
      const total = frame.length;
      emit({ slot, phase: 'start', index, count, sent: 0, total });
      let result: UploadResult;
      try {
        result = await this.uploadNow(frame, slot, {
          busyTimeoutMs,
          signal,
          onProgress: (sent, of) => emit({ slot, phase: 'sending', index, count, sent, total: of }),
        });
      } catch (error) {
        if (!(error instanceof DeviceError)) throw error;
        const detail = error.message.startsWith(`page ${slot}: `)
          ? error.message.slice(`page ${slot}: `.length)
          : error.message;
        throw new PushFailed(slot, new Map(results), `page ${slot}: ${detail}`, error);
      }
      results.set(slot, result);
      emit({ slot, phase: result === 'unchanged' ? 'unchanged' : 'done', index, count, sent: total, total });
      if (slot === shown && result === 'ok') {
        emit({ slot, phase: 'refreshing', index, count, sent: total, total });
      }
    }
    return results;
  }
}

/**
 * Upload order for a push: the slots other than `shown` in ascending order,
 * then `shown` if it is among them. Duplicates are ignored.
 */
export function pushOrder(slots: Iterable<number>, shown: number): number[] {
  const unique = [...new Set(slots)];
  const others = unique.filter((slot) => slot !== shown).sort((a, b) => a - b);
  return unique.includes(shown) ? [...others, shown] : others;
}

/**
 * Image chunk size for a link whose writes without response carry at most
 * `maxWriteLength` bytes: clamped to MIN_CHUNK..MAX_CHUNK; MIN_CHUNK when
 * unknown.
 */
export function chunkSizeFor(maxWriteLength: number | undefined): number {
  if (maxWriteLength === undefined || !Number.isFinite(maxWriteLength)) return MIN_CHUNK;
  return Math.min(MAX_CHUNK, Math.max(MIN_CHUNK, Math.floor(maxWriteLength)));
}

/**
 * Connect `transport`, start a session and unlock (see connectWithRetries
 * for the attempts). The session's options are `options` without `signal`.
 *
 * Web Bluetooth: call it straight from a user gesture; nothing is awaited
 * before transport.connect(), so the device chooser can open.
 *
 * @throws ConnectFailed (`could not connect after N attempts`), the first
 * non-retryable TransportError, or TransportError `cancelled` when `signal`
 * aborts between attempts.
 */
export async function connectSession(
  transport: Transport,
  options: ConnectSessionOptions = {},
): Promise<CalendarSession> {
  const { signal, ...sessionOptions } = options;
  const session = new CalendarSession(transport, sessionOptions);
  const log = makeLog('session', () => sessionOptions.log);
  const emit = (event: LinkEvent) => {
    try {
      sessionOptions.onLink?.(event);
    } catch {
      // Ignored, like a broken logger.
    }
  };
  await connectWithRetries(transport, connectPlan(sessionOptions, undefined), () => session.start(), log, emit, signal);
  return session;
}

/** How connectWithRetries goes about it; durations in milliseconds. */
interface ConnectPlan {
  readonly attempts: number;
  readonly retryDelayMs: number;
  readonly attemptTimeoutMs: number;
  readonly connectWindowMs: number;
  /** Start the first attempt no earlier than this (a Date.now() time). */
  readonly notBefore: number | undefined;
}

function connectPlan(options: SessionOptions, notBefore: number | undefined): ConnectPlan {
  return {
    attempts: Math.max(1, Math.floor(options.attempts ?? SESSION_DEFAULTS.attempts)),
    retryDelayMs: options.retryDelayMs ?? SESSION_DEFAULTS.retryDelayMs,
    attemptTimeoutMs: options.attemptTimeoutMs ?? SESSION_DEFAULTS.attemptTimeoutMs,
    connectWindowMs: options.connectWindowMs ?? SESSION_DEFAULTS.connectWindowMs,
    notBefore,
  };
}

/**
 * Bring up the link: transport.connect() with a short timeout
 * (attemptTimeoutMs), then `setUp` (unlock), retried `retryDelayMs` apart
 * while the failure is retryable. Disconnects after a failed attempt.
 *
 * - Before the first attempt it waits until `notBefore` (the end of a panel
 *   refresh), announced with a `waiting` event; without one, the first
 *   transport.connect() is called synchronously (Web Bluetooth's chooser
 *   needs the user gesture).
 * - It makes at least `attempts` attempts. While the device does not answer
 *   at all (timeouts, not found, no reply to unlock: an attempt that was not
 *   dropped by the device), it goes on until `connectWindowMs` after the
 *   first attempt started: the device advertises sparsely and ignores new
 *   links while its panel refreshes.
 * - A device that drops the link before notifications are on is most
 *   likely not in pairing mode; that does not add attempts, and the
 *   `failed` event says so (droppedWhileConnecting).
 *
 * Ends with a `connected` or a `gaveUp` event.
 *
 * @throws ConnectFailed, the first non-retryable error, or TransportError
 * `cancelled` when `signal` aborts while it waits.
 */
async function connectWithRetries(
  transport: Transport,
  plan: ConnectPlan,
  setUp: () => Promise<void>,
  log: (level: LogLevel, message: string) => void,
  emit: (event: LinkEvent) => void,
  signal: AbortSignal | undefined,
): Promise<void> {
  try {
    // Called synchronously: see above.
    await connectAttempts(transport, plan, setUp, log, emit, signal);
  } catch (error) {
    emit({ type: 'gaveUp', error });
    throw error;
  }
}

async function connectAttempts(
  transport: Transport,
  plan: ConnectPlan,
  setUp: () => Promise<void>,
  log: (level: LogLevel, message: string) => void,
  emit: (event: LinkEvent) => void,
  signal: AbortSignal | undefined,
): Promise<void> {
  if (plan.notBefore !== undefined && plan.notBefore > Date.now()) {
    emit({ type: 'waiting', until: plan.notBefore });
    log('info', `waiting ${seconds(plan.notBefore - Date.now())} for the panel refresh to end before connecting`);
    await pause(plan.notBefore - Date.now(), signal);
  }
  const deadline = Date.now() + plan.connectWindowMs;
  let last: unknown;
  let everyDropWhilePairing = true;
  let dropped = false;
  let attempt = 0;
  for (;;) {
    attempt++;
    emit({ type: 'attempt', attempt });
    let droppedNow: boolean;
    try {
      await transport.connect({ timeoutMs: plan.attemptTimeoutMs, signal });
      await setUp();
      if (attempt > 1) log('info', `connected on attempt ${attempt}`);
      emit({ type: 'connected', attempt });
      return;
    } catch (error) {
      await transport.disconnect();
      const retryable = error instanceof TransportError ? error.retryable : error instanceof DeviceError;
      if (!retryable) throw error;
      last = error;
      droppedNow = error instanceof TransportError && error.droppedWhileConnecting;
      if (!(error instanceof TransportError && error.duringPairing)) everyDropWhilePairing = false;
      log('warn', `attempt ${attempt} failed: ${describe(error)}`);
      if (droppedNow && !dropped) {
        log('warn', `the device dropped the link before notifications were on: ${PAIRING_MODE_STEPS}`);
      }
      dropped ||= droppedNow;
      emit({ type: 'failed', attempt, error, droppedWhileConnecting: droppedNow });
    }
    const timeLeft = Date.now() + plan.retryDelayMs < deadline;
    if (attempt >= plan.attempts && (droppedNow || !timeLeft)) break;
    await pause(plan.retryDelayMs, signal);
  }
  throw new ConnectFailed(attempt, last, everyDropWhilePairing, dropped);
}

/** sleep(), reporting an abort as TransportError `cancelled`. */
async function pause(ms: number, signal: AbortSignal | undefined): Promise<void> {
  try {
    await sleep(ms, signal);
  } catch (error) {
    throw new TransportError('cancelled', 'connecting was cancelled', { cause: error });
  }
}

// --- Helpers -----------------------------------------------------------------------

/**
 * Notifications waiting to be read, one FIFO per characteristic. A reader
 * asks for the next value with a given opcode; values with another opcode
 * are discarded (while it waits, or from the buffer when it asks).
 */
class ReplyInbox {
  private readonly buffers: Record<ProtocolCharacteristic, Uint8Array[]> = { command: [], image: [] };
  private readonly waiters: Partial<Record<ProtocolCharacteristic, { opcode: number; settle: Settle }>> = {};
  private closed: Error | undefined;

  deliver(characteristic: ProtocolCharacteristic, value: Uint8Array): void {
    const waiter = this.waiters[characteristic];
    if (!waiter) {
      this.buffers[characteristic].push(value);
    } else if (value[0] === waiter.opcode) {
      waiter.settle({ value });
    }
  }

  /** Forget what is buffered on `characteristic` (stale replies). */
  drain(characteristic: ProtocolCharacteristic): void {
    this.buffers[characteristic].length = 0;
  }

  /** Whether a value with `opcode` is buffered on `characteristic`. */
  has(characteristic: ProtocolCharacteristic, opcode: number): boolean {
    return this.buffers[characteristic].some((value) => value[0] === opcode);
  }

  /** The next value with `opcode`; NoReply after `timeoutMs`; the close error once closed. */
  next(
    characteristic: ProtocolCharacteristic,
    opcode: number,
    timeoutMs: number,
    signal?: AbortSignal,
  ): Promise<Uint8Array> {
    const buffer = this.buffers[characteristic];
    while (buffer.length > 0) {
      const value = buffer.shift() as Uint8Array;
      if (value[0] === opcode) return Promise.resolve(value);
    }
    if (this.closed) return Promise.reject(this.closed);
    if (signal?.aborted) return Promise.reject(abortReason(signal));
    return new Promise<Uint8Array>((resolve, reject) => {
      const settle: Settle = (outcome) => {
        clearTimeout(timer);
        signal?.removeEventListener('abort', onAbort);
        if (this.waiters[characteristic]?.settle === settle) delete this.waiters[characteristic];
        if ('value' in outcome) resolve(outcome.value);
        else reject(outcome.error);
      };
      const timer = setTimeout(() => {
        const hex = opcode.toString(16).padStart(2, '0');
        settle({ error: new NoReply(opcode, `no reply to opcode 0x${hex} within ${seconds(timeoutMs)}`) });
      }, timeoutMs);
      const onAbort = () => settle({ error: abortReason(signal) });
      signal?.addEventListener('abort', onAbort, { once: true });
      this.waiters[characteristic] = { opcode, settle };
    });
  }

  /** The link is gone: fail waiting readers and every read until reopen(). */
  close(error: Error): void {
    this.closed = error;
    this.drain('command');
    this.drain('image');
    for (const waiter of Object.values(this.waiters)) waiter?.settle({ error });
  }

  /** Accept reads again, forgetting what arrived meanwhile; true when it had been closed. */
  reopen(): boolean {
    if (!this.closed) return false;
    this.closed = undefined;
    this.drain('command');
    this.drain('image');
    return true;
  }
}

type Settle = (outcome: { value: Uint8Array } | { error: unknown }) => void;

function abortReason(signal: AbortSignal | undefined): unknown {
  return signal?.reason ?? new DOMException('The operation was aborted.', 'AbortError');
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) throw abortReason(signal);
}

/** Wait `ms`; rejects with the signal's reason when it aborts first. */
function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) return Promise.reject(abortReason(signal));
  return new Promise<void>((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timer);
      reject(abortReason(signal));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

function decodeText(bytes: Uint8Array): string {
  return new TextDecoder('utf-8', { fatal: false }).decode(bytes);
}

function describe(error: unknown): string {
  if (error instanceof Error) return error.message || error.name;
  return String(error);
}

function seconds(ms: number): string {
  return `${Number((ms / 1000).toFixed(1))} s`;
}
