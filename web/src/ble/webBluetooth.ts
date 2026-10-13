/**
 * Transport over the Web Bluetooth API: desktop and Android Chrome, and the
 * Bluefy browser on iPhone. Needs a secure context (https or localhost).
 *
 * - The device chooser lists what advertises the service A200 or a name
 *   starting with ADVERTISED_NAME_PREFIX; SERVICE and
 *   DEVICE_INFORMATION_SERVICE are requested as optional services (all in
 *   core/protocol.ts). The browser handles pairing when the encrypted
 *   characteristics are first used (enabling notifications). Bringing up the
 *   link and finding the services run under the connect timeout; enabling
 *   notifications may wait for the system pairing prompt, so it runs under
 *   the pairing timeout (never shorter). Neither uses the per-operation one.
 * - Browsers allow one GATT operation at a time per device and throw
 *   "GATT operation already in progress" otherwise, so every operation goes
 *   through one queue, with a timeout.
 * - Web Bluetooth cannot tell the ATT MTU. Writes without response are
 *   assumed to carry `writeLength` bytes (default 180: iOS negotiates an MTU
 *   of about 185); lower it if uploads fail on a link with a smaller MTU.
 * - When the link drops, pending and queued operations fail at once with
 *   TransportError `linkLost`. connect() afterwards reconnects to the same
 *   calendar without the chooser (and without a user gesture).
 */

import {
  ADVERTISED_NAME_PREFIX,
  ADVERTISED_SERVICE,
  CHAR_COMMAND,
  CHAR_FIRMWARE_REVISION,
  CHAR_IMAGE,
  CHAR_MODEL_NUMBER,
  DEVICE_INFORMATION_SERVICE,
  SERVICE,
} from '../core/protocol';
import {
  type ConnectOptions,
  connectFailure,
  type DisconnectReason,
  type Logger,
  makeLog,
  previewBytes,
  type ProtocolCharacteristic,
  type ReadableCharacteristic,
  type Transport,
  TransportError,
  type TransportNotification,
  type Unsubscribe,
  type WriteMode,
  notificationFailure,
  writeFailure,
} from './transport';

/** Bytes per write without response when nothing else is configured. */
export const DEFAULT_WRITE_LENGTH = 180;
/** How long bringing up the link and finding the services may take once a device is chosen. */
export const DEFAULT_CONNECT_TIMEOUT_MS = 60_000;
/** How long enabling notifications may take: the system pairing prompt may wait for the user. */
export const DEFAULT_PAIRING_TIMEOUT_MS = 60_000;
/** How long one GATT operation may take (the ATT transaction timeout is 30 s). */
export const DEFAULT_OPERATION_TIMEOUT_MS = 30_000;

/** The write methods a Web Bluetooth characteristic may have. */
export const WRITE_METHODS = ['writeValueWithoutResponse', 'writeValueWithResponse', 'writeValue'] as const;
export type WriteMethod = (typeof WRITE_METHODS)[number];

/**
 * How image data is written, for diagnostics:
 * - `auto`: as the session asks (without response), with the browser's
 *   dedicated method, or writeValue() where the browser lacks it.
 * - `withoutResponse` / `withResponse`: always that method; fails with
 *   TransportError `unsupported` where the browser lacks it. With response
 *   is slower but each packet is acknowledged.
 * Commands are always written with response (the command characteristic
 * allows nothing else), through the dedicated method or writeValue().
 */
export type WriteModeSetting = 'auto' | WriteMode;

export interface WebBluetoothOptions {
  /** The Web Bluetooth entry point. Default `navigator.bluetooth`; tests pass a fake. */
  readonly bluetooth?: Bluetooth;
  /** A device the browser already lets the page use (see rememberedDevice): connect() goes to it without the chooser. */
  readonly device?: BluetoothDevice;
  /** See WebBluetoothTransport.writeLength. Default DEFAULT_WRITE_LENGTH. */
  readonly writeLength?: number;
  /** See WebBluetoothTransport.writeMode. Default `auto`. */
  readonly writeMode?: WriteModeSetting;
  /**
   * Default timeout of connect() for bringing up the link and finding the
   * services (ConnectOptions.timeoutMs). Default DEFAULT_CONNECT_TIMEOUT_MS.
   */
  readonly connectTimeoutMs?: number;
  /**
   * Timeout of enabling notifications, where the pairing prompt may wait
   * for the user; never shorter than the connect timeout of the attempt.
   * Default DEFAULT_PAIRING_TIMEOUT_MS.
   */
  readonly pairingTimeoutMs?: number;
  /** Timeout of each other GATT operation. Default DEFAULT_OPERATION_TIMEOUT_MS. */
  readonly operationTimeoutMs?: number;
  /** Diagnostics log. */
  readonly log?: Logger;
}

/**
 * Whether this browser exposes Web Bluetooth at all (`navigator.bluetooth`).
 * Bluetooth may still be off; connect() reports that.
 */
export function hasWebBluetooth(): boolean {
  return typeof navigator !== 'undefined' && typeof navigator.bluetooth?.requestDevice === 'function';
}

/**
 * The device the browser already lets this page use (the one the user chose in the chooser earlier),
 * for connecting again without a tap; undefined when there is none or the browser cannot list them
 * (`getDevices`, as in Bluefy and Chrome).
 */
export async function rememberedDevice(bluetooth?: Bluetooth): Promise<BluetoothDevice | undefined> {
  const api = bluetooth ?? (typeof navigator === 'undefined' ? undefined : navigator.bluetooth);
  if (typeof api?.getDevices !== 'function') return undefined;
  const devices = await api.getDevices();
  return devices.find((device) => device.name?.startsWith(ADVERTISED_NAME_PREFIX)) ?? devices[0];
}

/** What the device chooser asks for: the calendar's advertising, and the services we use. */
export function requestDeviceOptions(): RequestDeviceOptions {
  return {
    filters: [{ services: [ADVERTISED_SERVICE] }, { namePrefix: ADVERTISED_NAME_PREFIX }],
    optionalServices: [SERVICE, DEVICE_INFORMATION_SERVICE],
  };
}

type GattCharacteristic = ProtocolCharacteristic | ReadableCharacteristic;

/** One connection (attempt) to the calendar. */
interface Link {
  readonly server: BluetoothRemoteGATTServer;
  readonly chars: Partial<Record<GattCharacteristic, BluetoothRemoteGATTCharacteristic>>;
  /** connect() finished for this link. */
  up: boolean;
  /** Why the link is gone; set once. */
  error: TransportError | undefined;
  /** Rejects with `error` once the link is gone; every operation races it. */
  readonly gone: Promise<never>;
  readonly reject: (error: TransportError) => void;
}

export class WebBluetoothTransport implements Transport {
  readonly kind = 'web-bluetooth';

  /**
   * Payload size assumed for one write without response, reported by
   * maxWriteLength() (Web Bluetooth does not expose the MTU). May be changed
   * between uploads.
   */
  writeLength: number;
  /** How image data is written; may be changed between uploads. */
  writeMode: WriteModeSetting;
  connectTimeoutMs: number;
  pairingTimeoutMs: number;
  operationTimeoutMs: number;
  /** Diagnostics log; may be set or replaced at any time. */
  logger: Logger | undefined;

  private readonly bluetoothOverride: Bluetooth | undefined;
  private device: BluetoothDevice | undefined;
  private link: Link | undefined;
  private connecting: Promise<void> | undefined;
  /** Tail of the GATT operation queue. */
  private queue: Promise<unknown> = Promise.resolve();
  private lastWritten: ProtocolCharacteristic | undefined;
  private readonly notificationListeners = new Set<(notification: TransportNotification) => void>();
  private readonly disconnectListeners = new Set<(reason: DisconnectReason) => void>();
  private readonly log = makeLog(this.kind, () => this.logger);

  constructor(options: WebBluetoothOptions = {}) {
    this.bluetoothOverride = options.bluetooth;
    this.writeLength = options.writeLength ?? DEFAULT_WRITE_LENGTH;
    this.writeMode = options.writeMode ?? 'auto';
    this.connectTimeoutMs = options.connectTimeoutMs ?? DEFAULT_CONNECT_TIMEOUT_MS;
    this.pairingTimeoutMs = options.pairingTimeoutMs ?? DEFAULT_PAIRING_TIMEOUT_MS;
    this.operationTimeoutMs = options.operationTimeoutMs ?? DEFAULT_OPERATION_TIMEOUT_MS;
    this.logger = options.log;
    this.adopt(options.device);
  }

  get connected(): boolean {
    return this.link?.up === true;
  }

  /**
   * Which write methods the browser offers on `characteristic` of the
   * current link; undefined while not connected. Some browsers (Bluefy)
   * expose no global BluetoothRemoteGATTCharacteristic to inspect
   * beforehand, so the diagnostics page asks the real characteristic.
   */
  writeMethods(characteristic: ProtocolCharacteristic): Record<WriteMethod, boolean> | undefined {
    const target = this.link?.up ? this.link.chars[characteristic] : undefined;
    if (!target) return undefined;
    const methods = target as unknown as Record<string, unknown>;
    return Object.fromEntries(WRITE_METHODS.map((name) => [name, typeof methods[name] === 'function'])) as Record<
      WriteMethod,
      boolean
    >;
  }

  get deviceName(): string | undefined {
    return this.device?.name ?? undefined;
  }

  /**
   * The first call must run inside a user gesture: it opens the device
   * chooser, synchronously, before anything else is awaited. Later calls
   * reconnect to the calendar chosen then.
   */
  connect(options: ConnectOptions = {}): Promise<void> {
    if (this.connected) return Promise.resolve();
    if (this.connecting) return this.connecting;
    let chosen: Promise<BluetoothDevice>;
    try {
      chosen = this.device ? Promise.resolve(this.device) : this.choose(options.signal);
    } catch (error) {
      return Promise.reject(error);
    }
    const attempt = this.setUp(chosen, options);
    this.connecting = attempt;
    const settle = () => {
      if (this.connecting === attempt) this.connecting = undefined;
    };
    attempt.then(settle, settle);
    return attempt;
  }

  async disconnect(): Promise<void> {
    const link = this.link;
    if (!link) return;
    const error = link.up
      ? new TransportError('linkLost', 'disconnected')
      : new TransportError('cancelled', 'disconnected while connecting');
    this.fail(link, error, 'requested');
  }

  /** Disconnect and forget the chosen calendar: the next connect() opens the chooser again. */
  async forget(): Promise<void> {
    await this.disconnect();
    this.adopt(undefined);
  }

  async write(characteristic: ProtocolCharacteristic, data: Uint8Array, mode: WriteMode): Promise<void> {
    const link = this.requireLink();
    const target = link.chars[characteristic];
    if (!target) throw new TransportError('linkLost', `${characteristic} characteristic missing`);
    const method = this.writeMethod(characteristic, mode, target);
    if (characteristic === 'command') {
      this.log('debug', `write command: ${previewBytes(data)}`);
    } else if (this.lastWritten !== 'image') {
      this.log('debug', `image data: ${data.length}-byte packets via ${methodName(method)}`);
    }
    this.lastWritten = characteristic;
    // A copy whose buffer holds exactly these bytes: `data` may be a view
    // into a whole frame, and not every implementation honours the offset.
    const bytes = data.slice();
    try {
      await this.operation(link, `write ${characteristic}`, () => {
        if (method === 'withoutResponse') return target.writeValueWithoutResponse(bytes);
        if (method === 'withResponse') return target.writeValueWithResponse(bytes);
        return target.writeValue(bytes);
      });
    } catch (error) {
      if (!(error instanceof TransportError)) throw error;
      const linkUp = link.error === undefined && link.server.connected;
      throw writeFailure(error, characteristic, method === 'withResponse', linkUp);
    }
  }

  async read(characteristic: ReadableCharacteristic): Promise<Uint8Array> {
    const link = this.requireLink();
    const target = link.chars[characteristic];
    if (!target) {
      throw new TransportError(
        'unsupported',
        `${characteristic} cannot be read: the Device Information service is not available to this browser`,
      );
    }
    return copyView(await this.operation(link, `read ${characteristic}`, () => target.readValue()));
  }

  canRead(characteristic: ReadableCharacteristic): boolean {
    return this.link?.up === true && this.link.chars[characteristic] !== undefined;
  }

  onNotification(listener: (notification: TransportNotification) => void): Unsubscribe {
    this.notificationListeners.add(listener);
    return () => {
      this.notificationListeners.delete(listener);
    };
  }

  onDisconnect(listener: (reason: DisconnectReason) => void): Unsubscribe {
    this.disconnectListeners.add(listener);
    return () => {
      this.disconnectListeners.delete(listener);
    };
  }

  /** Web Bluetooth does not expose the ATT MTU: this is the configured writeLength. */
  async maxWriteLength(): Promise<number | undefined> {
    return this.writeLength;
  }

  // --- Connecting -----------------------------------------------------------------

  private bluetooth(): Bluetooth {
    const api = this.bluetoothOverride ?? (typeof navigator === 'undefined' ? undefined : navigator.bluetooth);
    if (!api || typeof api.requestDevice !== 'function') {
      throw new TransportError('unsupported', 'this browser has no Web Bluetooth');
    }
    return api;
  }

  /** Opens the chooser. Runs synchronously up to requestDevice (user gesture). */
  private choose(signal: AbortSignal | undefined): Promise<BluetoothDevice> {
    const bluetooth = this.bluetooth();
    if (signal?.aborted) throw new TransportError('cancelled', 'connecting was cancelled');
    this.log('info', 'opening the device chooser');
    let request: Promise<BluetoothDevice>;
    try {
      request = bluetooth.requestDevice(requestDeviceOptions());
    } catch (error) {
      return Promise.reject(toTransportError(error, 'choosing a device'));
    }
    return request.then(
      (device) => {
        this.log('info', `chose ${device.name ?? 'a device'}`);
        return device;
      },
      (error: unknown) => {
        const failure = toTransportError(error, 'choosing a device');
        // A chooser closed without a pick needs the user (and a new gesture):
        // never report it as retryable.
        if (failure.retryable) throw new TransportError('cancelled', failure.message, { cause: error });
        throw failure;
      },
    );
  }

  private async setUp(chosen: Promise<BluetoothDevice>, options: ConnectOptions): Promise<void> {
    const device = await chosen;
    this.adopt(device);
    const server = device.gatt;
    if (!server) throw new TransportError('unsupported', 'the browser offers no GATT access to this device');
    if (options.signal?.aborted) throw new TransportError('cancelled', 'connecting was cancelled');

    const link = this.newLink(server);
    const timeoutMs = options.timeoutMs ?? this.connectTimeoutMs;
    const pairingTimeoutMs = Math.max(timeoutMs, this.pairingTimeoutMs);
    const limit = (what: string, ms: number) =>
      setTimeout(() => this.fail(link, new TransportError('timeout', `${what} took longer than ${seconds(ms)}`)), ms);
    let timer = limit('connecting', timeoutMs);
    const onAbort = () => this.fail(link, new TransportError('cancelled', 'connecting was cancelled'));
    options.signal?.addEventListener('abort', onAbort, { once: true });
    /** The device accepted the connection: a drop from now on is the device's doing. */
    let accepted = false;
    try {
      this.log('info', `connecting to ${device.name ?? 'the device'}`);
      await this.operation(link, 'connect', () => server.connect(), timeoutMs);
      accepted = true;
      const service = await this.operation(link, 'find the e-paper service', () => server.getPrimaryService(SERVICE));
      const command = await this.operation(link, 'find the command characteristic', () =>
        service.getCharacteristic(CHAR_COMMAND),
      );
      const image = await this.operation(link, 'find the image characteristic', () =>
        service.getCharacteristic(CHAR_IMAGE),
      );
      link.chars.command = command;
      link.chars.image = image;
      await this.findDeviceInformation(link);
      // The pairing prompt may appear now and wait for the user.
      clearTimeout(timer);
      timer = limit('enabling notifications (pairing included)', pairingTimeoutMs);
      // Listen before enabling, so nothing notified right away is lost. The
      // handlers are stable references: adding them twice is a no-op.
      command.addEventListener('characteristicvaluechanged', this.onCommandValue);
      image.addEventListener('characteristicvaluechanged', this.onImageValue);
      await this.enableNotifications(link, 'command', command, pairingTimeoutMs);
      await this.enableNotifications(link, 'image', image, pairingTimeoutMs);
      if (link.error) throw link.error;
      link.up = true;
      this.lastWritten = undefined;
      this.log('info', 'connected, notifications on');
    } catch (error) {
      // A drop while enabling notifications keeps its mark (see duringPairing).
      const marked = error instanceof TransportError && error.duringPairing;
      let failure = marked ? error : (link.error ?? toTransportError(error, 'connecting'));
      // Asked before fail() below, which disconnects the server itself.
      if (accepted) failure = connectFailure(failure, link.error === undefined && server.connected);
      this.fail(link, failure);
      this.log('warn', failure.message);
      throw failure;
    } finally {
      clearTimeout(timer);
      options.signal?.removeEventListener('abort', onAbort);
    }
  }

  /**
   * Turn on notifications for `characteristic`. This is the first use of the
   * encrypted characteristics: the browser pairs here the first time (the
   * system prompt may wait for the user), and a stale pairing fails here.
   */
  private async enableNotifications(
    link: Link,
    characteristic: ProtocolCharacteristic,
    target: BluetoothRemoteGATTCharacteristic,
    timeoutMs: number,
  ): Promise<void> {
    try {
      await this.operation(link, `enable ${characteristic} notifications`, () => target.startNotifications(), timeoutMs);
    } catch (error) {
      const failure = toTransportError(error, `enabling ${characteristic} notifications`);
      // The disconnect event may come after the failed call: ask the server too.
      const linkUp = link.error === undefined && link.server.connected;
      throw notificationFailure(failure, linkUp, failure.cause ?? error);
    }
  }

  /**
   * Model number and firmware revision. Optional: missing ones fail when
   * read (and without the firmware revision the session uploads without its
   * flush barrier).
   */
  private async findDeviceInformation(link: Link): Promise<void> {
    const info = await this.findOptional(link, 'find Device Information', () =>
      link.server.getPrimaryService(DEVICE_INFORMATION_SERVICE),
    );
    if (!info) return;
    link.chars.modelNumber = await this.findOptional(link, 'find the model number', () =>
      info.getCharacteristic(CHAR_MODEL_NUMBER),
    );
    link.chars.firmwareRevision = await this.findOptional(link, 'find the firmware revision', () =>
      info.getCharacteristic(CHAR_FIRMWARE_REVISION),
    );
  }

  /**
   * One discovery step whose result is optional: undefined when it fails
   * while the link stays up. A failure other than "not there" is tried once
   * more, so one flaky discovery does not cost the rest of the link.
   */
  private async findOptional<T>(link: Link, label: string, start: () => Promise<T>): Promise<T | undefined> {
    for (let attempt = 1; ; attempt++) {
      try {
        return await this.operation(link, label, start);
      } catch (error) {
        if (link.error) throw link.error;
        const failure = toTransportError(error, label);
        if (failure.code === 'notFound' || attempt >= 2) {
          this.log('warn', `Device Information unavailable: ${failure.message}`);
          return undefined;
        }
        this.log('info', `${failure.message}; trying once more`);
      }
    }
  }

  private newLink(server: BluetoothRemoteGATTServer): Link {
    let reject!: (error: TransportError) => void;
    const gone = new Promise<never>((_, rejectGone) => {
      reject = rejectGone;
    });
    gone.catch(() => undefined);
    const link: Link = { server, chars: {}, up: false, error: undefined, gone, reject };
    this.link = link;
    return link;
  }

  /** Remember `device` and follow its disconnects. */
  private adopt(device: BluetoothDevice | undefined): void {
    if (device === this.device) return;
    this.device?.removeEventListener('gattserverdisconnected', this.onGattDisconnected);
    this.device = device;
    device?.addEventListener('gattserverdisconnected', this.onGattDisconnected);
  }

  /** The link is gone: fail everything pending on it, close it and tell the listeners. */
  private fail(link: Link, error: TransportError, reason: DisconnectReason = 'lost'): void {
    if (link.error) return;
    const wasUp = link.up;
    link.error = error;
    link.up = false;
    link.reject(error);
    link.chars.command?.removeEventListener('characteristicvaluechanged', this.onCommandValue);
    link.chars.image?.removeEventListener('characteristicvaluechanged', this.onImageValue);
    if (this.link === link) {
      this.link = undefined;
      try {
        // Also aborts a connect() still in progress.
        link.server.disconnect();
      } catch {
        // Already gone.
      }
    }
    if (!wasUp) return;
    this.log(reason === 'requested' ? 'info' : 'warn', `link down (${reason}): ${error.message}`);
    for (const listener of [...this.disconnectListeners]) {
      try {
        listener(reason);
      } catch (listenerError) {
        this.log('error', `disconnect listener failed: ${describe(listenerError)}`);
      }
    }
  }

  private readonly onGattDisconnected = (): void => {
    const link = this.link;
    // A connected server means the event is a late one about an earlier link.
    if (!link || link.server.connected) return;
    this.fail(link, new TransportError('linkLost', 'the device disconnected'));
  };

  // --- Operations -----------------------------------------------------------------

  private requireLink(): Link {
    const link = this.link;
    if (!link?.up) throw new TransportError('linkLost', 'not connected');
    return link;
  }

  /**
   * Run one GATT operation on `link` after every earlier one settled. It fails
   * with the link's error as soon as the link goes down, and with `timeout`
   * (dropping the link, whose GATT state is then unknown) after `timeoutMs`
   * (default operationTimeoutMs, read when the operation starts).
   */
  private operation<T>(link: Link, label: string, start: () => Promise<T>, timeoutMs?: number): Promise<T> {
    const run = async (): Promise<T> => {
      if (link.error) throw link.error;
      const limitMs = timeoutMs ?? this.operationTimeoutMs;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          const error = new TransportError('timeout', `${label}: no answer within ${seconds(limitMs)}`);
          reject(error);
          this.fail(link, error);
        }, limitMs);
      });
      const pending = Promise.resolve().then(start);
      pending.catch(() => undefined); // it may lose the race below and fail later
      try {
        return await Promise.race([pending, link.gone, timeout]);
      } catch (error) {
        throw link.error ?? toTransportError(error, label);
      } finally {
        clearTimeout(timer);
      }
    };
    const result = this.queue.then(run, run);
    this.queue = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  private writeMethod(
    characteristic: ProtocolCharacteristic,
    requested: WriteMode,
    target: BluetoothRemoteGATTCharacteristic,
  ): WriteMode | 'writeValue' {
    const forced = characteristic === 'image' && this.writeMode !== 'auto';
    const mode = forced ? (this.writeMode as WriteMode) : requested;
    const method = mode === 'withResponse' ? target.writeValueWithResponse : target.writeValueWithoutResponse;
    if (typeof method === 'function') return mode;
    if (forced) throw new TransportError('unsupported', `this browser has no ${methodName(mode)}`);
    return 'writeValue';
  }

  // --- Notifications --------------------------------------------------------------

  private readonly onCommandValue = (event: Event): void => this.deliver('command', event);
  private readonly onImageValue = (event: Event): void => this.deliver('image', event);

  private deliver(characteristic: ProtocolCharacteristic, event: Event): void {
    const view = (event.target as BluetoothRemoteGATTCharacteristic | null)?.value;
    if (!view) return;
    const value = copyView(view);
    this.log('debug', `notified ${characteristic}: ${previewBytes(value)}`);
    for (const listener of [...this.notificationListeners]) {
      try {
        listener({ characteristic, value });
      } catch (error) {
        this.log('error', `notification listener failed: ${describe(error)}`);
      }
    }
  }
}

/**
 * A platform error as a TransportError. Browsers report Bluetooth failures as
 * DOMExceptions whose names are coarse, so the message is consulted too.
 */
export function toTransportError(error: unknown, what: string): TransportError {
  if (error instanceof TransportError) return error;
  const name = typeof error === 'object' && error !== null && 'name' in error ? String(error.name) : '';
  const detail = describe(error);
  const message = `${what}: ${detail}`;
  const options = { cause: error };
  if (/auth|encrypt|not paired|pairing|bond/i.test(detail)) return new TransportError('bondLost', message, options);
  // The link is fine; the browser or the calendar does not allow this
  // operation (e.g. a characteristic property it lacks). Retrying cannot help.
  if (name === 'NotSupportedError' || /not permitted|not supported/i.test(detail)) {
    return new TransportError('unsupported', message, options);
  }
  switch (name) {
    case 'NotFoundError':
      if (/cancel/i.test(detail)) return new TransportError('cancelled', message, options);
      if (/adapter|bluetooth is (off|disabled)|not available/i.test(detail)) {
        return new TransportError('unavailable', message, options);
      }
      return new TransportError('notFound', message, options);
    case 'NotAllowedError':
    case 'SecurityError':
      return new TransportError('unavailable', message, options);
    case 'TimeoutError':
      return new TransportError('timeout', message, options);
    default:
      return new TransportError('linkLost', message, options);
  }
}

function copyView(view: DataView): Uint8Array {
  return new Uint8Array(view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength));
}

function methodName(method: WriteMode | 'writeValue'): string {
  if (method === 'withResponse') return 'writeValueWithResponse';
  if (method === 'withoutResponse') return 'writeValueWithoutResponse';
  return 'writeValue';
}

function describe(error: unknown): string {
  if (error instanceof Error) return error.message || error.name;
  return String(error);
}

function seconds(ms: number): string {
  return `${Number((ms / 1000).toFixed(1))} s`;
}
