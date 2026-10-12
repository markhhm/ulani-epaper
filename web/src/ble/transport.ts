/**
 * The BLE link to one calendar, as the session sees it.
 *
 * Every Bluetooth backend implements Transport: Web Bluetooth in browsers
 * (webBluetooth.ts), the native plugin in the Android app, and fakes in tests.
 * The protocol itself lives in the session (session/session.ts), which only
 * talks to a Transport; a backend only moves bytes.
 *
 * The calendar has two protocol characteristics, both needing an encrypted
 * (bonded) link:
 * - `command`: requests are written with response; each reply arrives as a
 *   notification on the same characteristic.
 * - `image`: frame data is written without response; the upload's final
 *   result arrives as a notification on the same characteristic.
 * Two standard Device Information strings are readable as well.
 *
 * Backends map these names to the UUIDs in core/protocol.ts and report
 * failures as TransportError, never as raw platform errors, so the session can
 * tell retryable failures from ones that need the user.
 */

import { DeviceError } from '../core/protocol';

/** The characteristics that carry the protocol (written to, notified from). */
export type ProtocolCharacteristic = 'command' | 'image';

/**
 * The characteristics a transport can read. Reading `firmwareRevision`
 * between image chunks doubles as a flow-control barrier: ATT requests are
 * serialised, so the read completes only after queued writes have gone out.
 */
export type ReadableCharacteristic = 'modelNumber' | 'firmwareRevision';

/**
 * `withResponse`: resolves once the calendar acknowledged the write (used for
 * `command`). `withoutResponse`: resolves once the platform accepted the
 * packet, which may only mean it was queued (used for `image`).
 */
export type WriteMode = 'withResponse' | 'withoutResponse';

/** One notification from the calendar. */
export interface TransportNotification {
  readonly characteristic: ProtocolCharacteristic;
  /** The notified value; the transport never reuses or changes this buffer. */
  readonly value: Uint8Array;
}

/** `requested`: disconnect() was called. `lost`: the link dropped for any other reason. */
export type DisconnectReason = 'requested' | 'lost';

/** Removes the listener it was returned for; calling it again does nothing. */
export type Unsubscribe = () => void;

export interface ConnectOptions {
  /**
   * Give up when the link is not up, with its services found, after this
   * many milliseconds (TransportError `timeout`). Does not include the time
   * the user spends in a device chooser, nor enabling notifications: a
   * pairing prompt may appear there and wait for the user, so that step gets
   * the backend's pairing timeout (never less than this). Default: backend
   * specific.
   */
  readonly timeoutMs?: number;
  /** Abort the attempt (TransportError `cancelled`). */
  readonly signal?: AbortSignal;
}

/**
 * - `unsupported`: this browser or device has no usable Bluetooth API, or
 *   lacks a feature that was asked for explicitly, or the calendar does not
 *   permit an operation (such as a write with response to `image`).
 * - `unavailable`: Bluetooth is off, or permission was denied.
 * - `cancelled`: the user closed the device chooser, or the signal aborted.
 * - `notFound`: no calendar was found.
 * - `bondLost`: the calendar refused the encrypted link (pair it again).
 * - `linkLost`: the link dropped, or an operation failed on an open link.
 * - `timeout`: connecting or a GATT operation took too long.
 */
export type TransportErrorCode =
  | 'unsupported'
  | 'unavailable'
  | 'cancelled'
  | 'notFound'
  | 'bondLost'
  | 'linkLost'
  | 'timeout';

/** A Bluetooth failure, classified. */
export class TransportError extends DeviceError {
  override name = 'TransportError';
  readonly code: TransportErrorCode;
  /**
   * The failure happened while notifications were being enabled: the first
   * use of the encrypted characteristics, where the phone pairs or uses its
   * stored pairing. A link that drops at this step on every attempt usually
   * means a stale pairing (the calendar no longer knows the phone).
   */
  readonly duringPairing: boolean;
  /**
   * The device dropped the link during connect(), after it had accepted the
   * connection and before notifications were on (while the services were
   * being found or notifications enabled; duringPairing implies it). A
   * device that is not in pairing mode does this to a phone it has not been
   * paired with yet.
   */
  readonly droppedWhileConnecting: boolean;

  constructor(
    code: TransportErrorCode,
    message: string,
    options?: { cause?: unknown; duringPairing?: boolean; droppedWhileConnecting?: boolean },
  ) {
    super(message, options !== undefined && 'cause' in options ? { cause: options.cause } : undefined);
    this.code = code;
    this.duringPairing = options?.duringPairing === true;
    this.droppedWhileConnecting = this.duringPairing || options?.droppedWhileConnecting === true;
  }

  /**
   * Whether setting up the connection again may help. The calendar advertises
   * sparsely and stays silent for ~40 s while its panel refreshes, so not
   * finding it, link drops and timeouts are often transient; the other codes
   * need the user.
   */
  get retryable(): boolean {
    return this.code === 'notFound' || this.code === 'linkLost' || this.code === 'timeout';
  }
}

/**
 * A GATT link to one calendar. Minimal and promise-based; at most one
 * operation of each kind is expected in flight at a time (the session
 * serialises its writes and reads).
 */
export interface Transport {
  /** Backend name for diagnostics, e.g. `web-bluetooth`. */
  readonly kind: string;

  /** Whether the link is up (connect() resolved and no disconnect since). */
  readonly connected: boolean;

  /** Advertised name of the calendar, once known (e.g. after connect). */
  readonly deviceName: string | undefined;

  /**
   * Find the calendar, connect, discover the services and enable
   * notifications on both protocol characteristics. Resolves once
   * notifications are on; does nothing when the link is already up.
   * Connecting again after a disconnect reuses the calendar chosen before,
   * where the platform allows it.
   *
   * Web Bluetooth: the first call must run inside a user gesture (a click),
   * because it opens the browser's device chooser.
   *
   * @throws TransportError
   */
  connect(options?: ConnectOptions): Promise<void>;

  /**
   * Close the link. Pending operations fail with TransportError `linkLost`.
   * Never rejects; calling it when not connected does nothing.
   */
  disconnect(): Promise<void>;

  /**
   * Write `data` (at most maxWriteLength bytes for `withoutResponse`) to a
   * protocol characteristic.
   *
   * @throws TransportError
   */
  write(characteristic: ProtocolCharacteristic, data: Uint8Array, mode: WriteMode): Promise<void>;

  /**
   * Read a characteristic's current value.
   *
   * @throws TransportError
   */
  read(characteristic: ReadableCharacteristic): Promise<Uint8Array>;

  /**
   * Whether read(`characteristic`) can work on the current link (the calendar
   * offers it and the platform can reach it). False when not connected.
   * Absent when the backend cannot tell; then only a read finds out.
   */
  canRead?(characteristic: ReadableCharacteristic): boolean;

  /**
   * Listen to notifications from both protocol characteristics. Listeners run
   * synchronously, in arrival order across both characteristics.
   * Notifications that arrive while nobody listens are dropped.
   */
  onNotification(listener: (notification: TransportNotification) => void): Unsubscribe;

  /** Listen for the link going down; called once per connection. */
  onDisconnect(listener: (reason: DisconnectReason) => void): Unsubscribe;

  /**
   * Largest payload of one write without response on the current link (ATT
   * MTU minus 3), as far as the backend knows. Absent, or resolving to
   * undefined, when it has no idea; the session then uses the smallest size
   * every link allows.
   */
  maxWriteLength?(): Promise<number | undefined>;
}

/** What to do about a pairing that does not work, for technical messages. */
export const REPAIR_STEPS =
  'forget the device in the Bluetooth settings, hold its button about 5 s until the LED blinks green, ' +
  'then connect again and accept pairing';

/** What to do when the device drops a phone it does not know, for technical messages. */
export const PAIRING_MODE_STEPS =
  'if this phone has not been paired with it yet, hold its button about 5 s until the LED blinks green ' +
  '(pairing mode), then connect again';

/**
 * What a backend reports when connect() failed after the device had
 * accepted the connection (`failure`, already classified). A dropped link
 * (`linkLost` while `linkUp` is false) is marked droppedWhileConnecting;
 * anything else, or a link that is still up, stays as it is.
 */
export function connectFailure(failure: TransportError, linkUp: boolean): TransportError {
  if (failure.code !== 'linkLost' || linkUp || failure.droppedWhileConnecting) return failure;
  return new TransportError('linkLost', failure.message, {
    ...(failure.cause === undefined ? {} : { cause: failure.cause }),
    droppedWhileConnecting: true,
  });
}

/**
 * What a backend reports when enabling notifications failed (`failure`,
 * already classified; `cause` is the platform's error).
 * - The link dropped (`linkLost` with the link down): the same failure,
 *   marked duringPairing (and so droppedWhileConnecting). Still retryable;
 *   connectSession turns a run of these into a hint to pair again.
 * - `linkLost` while the link stays up: the calendar refused the encrypted
 *   characteristic, so the pairing does not work: `bondLost`.
 * - Anything else (timeout, cancelled, bondLost, unsupported): as is.
 */
export function notificationFailure(failure: TransportError, linkUp: boolean, cause: unknown): TransportError {
  if (failure.code !== 'linkLost') return failure;
  if (!linkUp) {
    return new TransportError('linkLost', `${failure.message} (while enabling notifications)`, {
      cause: failure,
      duringPairing: true,
    });
  }
  return new TransportError('bondLost', `${failure.message}; the encrypted link was refused: ${REPAIR_STEPS}`, {
    cause,
  });
}

/**
 * What a backend reports for a failed write. The image characteristic only
 * takes writes without response, so a write with response to it that fails
 * while the link stays up is the calendar refusing that kind of write: no
 * retry helps, so it becomes `unsupported`. Anything else is `failure` as is.
 */
export function writeFailure(
  failure: TransportError,
  characteristic: ProtocolCharacteristic,
  withResponse: boolean,
  linkUp: boolean,
): TransportError {
  if (characteristic !== 'image' || !withResponse || !linkUp) return failure;
  if (failure.code !== 'linkLost' && failure.code !== 'unsupported') return failure;
  return new TransportError(
    'unsupported',
    `the device does not accept image data written with response (${failure.message})`,
    { cause: failure },
  );
}

// --- Diagnostics log ------------------------------------------------------------

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

/** One diagnostics line from a transport or the session. */
export interface LogEntry {
  /** When it happened: milliseconds since the epoch (Date.now()). */
  readonly time: number;
  readonly level: LogLevel;
  /** Who logged it: a transport's `kind`, or `session`. */
  readonly source: string;
  /** Human-readable; byte values appear only as short previews (see previewBytes). */
  readonly message: string;
}

/**
 * Receives diagnostics lines. Must not throw (errors it throws are ignored)
 * and should return quickly: it runs inline with the Bluetooth traffic.
 */
export type Logger = (entry: LogEntry) => void;

/** Hex bytes shown by previewBytes before it cuts off. */
export const LOG_PREVIEW_BYTES = 16;

/**
 * Space-separated lower-case hex of at most `limit` bytes, followed by the
 * total length when `data` is longer, e.g. `02 00` or
 * `00 11 22 … (192000 bytes)`. Logs only ever show bytes through this, so a
 * frame never ends up in a log.
 */
export function previewBytes(data: Uint8Array, limit: number = LOG_PREVIEW_BYTES): string {
  const shown = Array.from(data.subarray(0, Math.max(0, limit)), (byte) => byte.toString(16).padStart(2, '0'));
  if (data.length <= shown.length) return shown.join(' ') || '(empty)';
  return `${shown.join(' ')} … (${data.length} bytes)`;
}

/**
 * A function that logs through `logger` (if any) as `source`, stamping each
 * entry with Date.now() and swallowing errors the logger throws.
 */
export function makeLog(
  source: string,
  logger: () => Logger | undefined,
): (level: LogLevel, message: string) => void {
  return (level, message) => {
    const sink = logger();
    if (!sink) return;
    try {
      sink({ time: Date.now(), level, source, message });
    } catch {
      // A broken logger must never break the link.
    }
  };
}
