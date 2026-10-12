/**
 * Transport over the @capacitor-community/bluetooth-le plugin: the native
 * Bluetooth LE stack of the Android app (Capacitor).
 *
 * - The first connect() loads the plugin and initialises it, which asks for
 *   the Bluetooth permissions (Nearby devices on Android 12+, location on
 *   older versions). If Bluetooth is off, it asks the system to turn it on.
 *   Android 11 and older also need Location turned on to find devices;
 *   connect() reports `unavailable` before opening the chooser when it is off.
 * - The device chooser is the plugin's native dialog. It lists what
 *   advertises the service A200 (ADVERTISED_SERVICE). The Web Bluetooth
 *   backend also accepts names starting with ADVERTISED_NAME_PREFIX, but the
 *   plugin combines a name prefix with the service filter instead of offering
 *   either one, so only the service is used here; the calendar always
 *   advertises it.
 * - The plugin connects, discovers the services and asks for an ATT MTU of
 *   512; maxWriteLength() reports what the calendar agreed to, minus the
 *   ATT header.
 * - Enabling notifications on the encrypted characteristics makes Android
 *   pair with the calendar the first time (a system prompt), so that step
 *   runs under the pairing timeout, which is generous, rather than the
 *   connect timeout.
 * - Every GATT operation goes through one queue, with a timeout. When the
 *   link drops, pending and queued operations fail at once with
 *   TransportError `linkLost`; connect() afterwards reconnects to the same
 *   calendar without the chooser.
 */

import type {
  BleClientInterface,
  BleDevice,
  BleService,
  DisplayStrings,
  RequestBleDeviceOptions,
} from '@capacitor-community/bluetooth-le';
import {
  ADVERTISED_SERVICE,
  ATT_HEADER,
  CHAR_COMMAND,
  CHAR_FIRMWARE_REVISION,
  CHAR_IMAGE,
  CHAR_MODEL_NUMBER,
  DEVICE_INFORMATION_SERVICE,
  SERVICE,
} from '../core/protocol';
import { getLocale, type Locale, t } from '../i18n';
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
import type { WriteModeSetting } from './webBluetooth';

/** How long bringing up the link and finding the services may take once a device is chosen. */
export const DEFAULT_CONNECT_TIMEOUT_MS = 60_000;
/** How long enabling notifications may take: the system pairing prompt may wait for the user. */
export const DEFAULT_PAIRING_TIMEOUT_MS = 60_000;
/** How long one GATT operation may take (the ATT transaction timeout is 30 s). */
export const DEFAULT_OPERATION_TIMEOUT_MS = 30_000;

/** The part of the plugin's BleClient this transport uses; tests pass a fake. */
export type BleClientApi = Pick<
  BleClientInterface,
  | 'initialize'
  | 'isEnabled'
  | 'requestEnable'
  | 'isLocationEnabled'
  | 'setDisplayStrings'
  | 'requestDevice'
  | 'connect'
  | 'disconnect'
  | 'getServices'
  | 'getMtu'
  | 'startNotifications'
  | 'write'
  | 'writeWithoutResponse'
  | 'read'
>;

export interface CapacitorBleOptions {
  /** The plugin client. Default: the plugin's BleClient, loaded on first use. */
  readonly client?: BleClientApi;
  /** See CapacitorBleTransport.writeMode. Default `auto`. */
  readonly writeMode?: WriteModeSetting;
  /** Default timeout of connect() (ConnectOptions.timeoutMs). Default DEFAULT_CONNECT_TIMEOUT_MS. */
  readonly connectTimeoutMs?: number;
  /**
   * Timeout of enabling notifications, where the pairing prompt may wait
   * for the user; never shorter than the connect timeout of the attempt.
   * Default DEFAULT_PAIRING_TIMEOUT_MS.
   */
  readonly pairingTimeoutMs?: number;
  /** Timeout of each GATT operation. Default DEFAULT_OPERATION_TIMEOUT_MS. */
  readonly operationTimeoutMs?: number;
  /** Android's major version, or undefined when unknown. Default: read from navigator.userAgent. */
  readonly androidVersion?: () => number | undefined;
  /** Diagnostics log. */
  readonly log?: Logger;
}

/** Technical message when Location is off where scans need it. errors.ts matches `location is off`. */
export const LOCATION_OFF = 'location is off; Android 11 and older need it on to find Bluetooth devices';

/** Android's major version from a user agent string (`… Android 11; …`), or undefined. */
export function androidVersionOf(userAgent: string): number | undefined {
  const match = /\bAndroid (\d+)/.exec(userAgent);
  return match ? Number(match[1]) : undefined;
}

function androidVersionFromBrowser(): number | undefined {
  return typeof navigator === 'undefined' ? undefined : androidVersionOf(navigator.userAgent ?? '');
}

/** What the device chooser asks for: the calendar's advertised service, and the services we use. */
export function requestDeviceOptions(): RequestBleDeviceOptions {
  return {
    services: [ADVERTISED_SERVICE],
    optionalServices: [SERVICE, DEVICE_INFORMATION_SERVICE],
  };
}

/** Texts of the plugin's native device chooser (src/i18n.ts). */
export function chooserStrings(locale: Locale): Required<DisplayStrings> {
  return {
    scanning: t('chooser.scanning', undefined, locale),
    cancel: t('chooser.cancel', undefined, locale),
    availableDevices: t('chooser.found', undefined, locale),
    noDeviceFound: t('chooser.none', undefined, locale),
  };
}

/** The plugin's BleClient, loaded only when the native backend is used. */
async function loadBleClient(): Promise<BleClientApi> {
  const { BleClient } = await import('@capacitor-community/bluetooth-le');
  // This transport already runs one GATT operation at a time. Without the
  // plugin's own queue, disconnect() is not held up behind a stuck write.
  BleClient.disableQueue();
  return BleClient;
}

const UUIDS: Record<ProtocolCharacteristic | ReadableCharacteristic, readonly [string, string]> = {
  command: [SERVICE, CHAR_COMMAND],
  image: [SERVICE, CHAR_IMAGE],
  modelNumber: [DEVICE_INFORMATION_SERVICE, CHAR_MODEL_NUMBER],
  firmwareRevision: [DEVICE_INFORMATION_SERVICE, CHAR_FIRMWARE_REVISION],
};

/** One connection (attempt) to the calendar. */
interface Link {
  readonly client: BleClientApi;
  readonly deviceId: string;
  /** connect() finished for this link. */
  up: boolean;
  /** Why the link is gone; set once. */
  error: TransportError | undefined;
  /** Rejects with `error` once the link is gone; every operation races it. */
  readonly gone: Promise<never>;
  readonly reject: (error: TransportError) => void;
  /** The Device Information characteristics the calendar has. */
  readonly readable: Set<ReadableCharacteristic>;
  /** Negotiated ATT MTU, once known. */
  mtu: number | undefined;
}

export class CapacitorBleTransport implements Transport {
  readonly kind = 'capacitor-ble';

  /** How image data is written (`auto`: as the session asks); may be changed between uploads. */
  writeMode: WriteModeSetting;
  connectTimeoutMs: number;
  pairingTimeoutMs: number;
  operationTimeoutMs: number;
  /** Diagnostics log; may be set or replaced at any time. */
  logger: Logger | undefined;

  private readonly clientOverride: BleClientApi | undefined;
  private readonly androidVersion: () => number | undefined;
  /** The initialised client; reset when initialising failed, so the next connect() asks again. */
  private initializing: Promise<BleClientApi> | undefined;
  private device: BleDevice | undefined;
  private link: Link | undefined;
  private connecting: Promise<void> | undefined;
  /** Closing of the previous link; a new connection waits for it. */
  private closing: Promise<void> = Promise.resolve();
  /** Tail of the GATT operation queue. */
  private queue: Promise<unknown> = Promise.resolve();
  private lastWritten: ProtocolCharacteristic | undefined;
  private readonly notificationListeners = new Set<(notification: TransportNotification) => void>();
  private readonly disconnectListeners = new Set<(reason: DisconnectReason) => void>();
  private readonly log = makeLog(this.kind, () => this.logger);

  constructor(options: CapacitorBleOptions = {}) {
    this.clientOverride = options.client;
    this.androidVersion = options.androidVersion ?? androidVersionFromBrowser;
    this.writeMode = options.writeMode ?? 'auto';
    this.connectTimeoutMs = options.connectTimeoutMs ?? DEFAULT_CONNECT_TIMEOUT_MS;
    this.pairingTimeoutMs = options.pairingTimeoutMs ?? DEFAULT_PAIRING_TIMEOUT_MS;
    this.operationTimeoutMs = options.operationTimeoutMs ?? DEFAULT_OPERATION_TIMEOUT_MS;
    this.logger = options.log;
  }

  get connected(): boolean {
    return this.link?.up === true;
  }

  get deviceName(): string | undefined {
    return this.device?.name ?? undefined;
  }

  /** The first call opens the device chooser; later calls reconnect to the calendar chosen then. */
  connect(options: ConnectOptions = {}): Promise<void> {
    if (this.connected) return Promise.resolve();
    if (this.connecting) return this.connecting;
    const attempt = this.setUp(options);
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
    this.device = undefined;
  }

  async write(characteristic: ProtocolCharacteristic, data: Uint8Array, mode: WriteMode): Promise<void> {
    const link = this.requireLink();
    const method = this.writeMethod(characteristic, mode);
    if (characteristic === 'command') {
      this.log('debug', `write command: ${previewBytes(data)}`);
    } else if (this.lastWritten !== 'image') {
      this.log('debug', `image data: ${data.length}-byte packets, written ${method}`);
    }
    this.lastWritten = characteristic;
    const [service, uuid] = UUIDS[characteristic];
    // A DataView over a copy that holds exactly these bytes: `data` may be a
    // view into a whole frame.
    const value = new DataView(data.slice().buffer);
    const options = { timeout: this.operationTimeoutMs };
    try {
      await this.operation(link, `write ${characteristic}`, () =>
        method === 'withoutResponse'
          ? link.client.writeWithoutResponse(link.deviceId, service, uuid, value, options)
          : link.client.write(link.deviceId, service, uuid, value, options),
      );
    } catch (error) {
      if (!(error instanceof TransportError)) throw error;
      throw writeFailure(error, characteristic, method === 'withResponse', link.error === undefined);
    }
  }

  async read(characteristic: ReadableCharacteristic): Promise<Uint8Array> {
    const link = this.requireLink();
    if (!link.readable.has(characteristic)) {
      throw new TransportError('unsupported', `${characteristic} cannot be read: the device does not offer it`);
    }
    const [service, uuid] = UUIDS[characteristic];
    const view = await this.operation(link, `read ${characteristic}`, () =>
      link.client.read(link.deviceId, service, uuid, { timeout: this.operationTimeoutMs }),
    );
    return copyView(view);
  }

  canRead(characteristic: ReadableCharacteristic): boolean {
    return this.link?.up === true && this.link.readable.has(characteristic);
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

  /** ATT MTU of the current link minus the ATT header; undefined when not connected or unknown. */
  async maxWriteLength(): Promise<number | undefined> {
    const link = this.link;
    if (!link?.up) return undefined;
    if (link.mtu === undefined) link.mtu = await this.queryMtu(link);
    return link.mtu === undefined ? undefined : link.mtu - ATT_HEADER;
  }

  // --- Connecting -----------------------------------------------------------------

  /** The plugin, initialised (permissions granted), with Bluetooth on. */
  private async ready(): Promise<BleClientApi> {
    if (!this.initializing) {
      const attempt = this.initialize();
      this.initializing = attempt;
      attempt.catch(() => {
        if (this.initializing === attempt) this.initializing = undefined;
      });
    }
    let client: BleClientApi;
    try {
      client = await this.initializing;
    } catch (error) {
      throw toTransportError(error, 'getting Bluetooth permission');
    }
    let enabled = await client.isEnabled().catch(() => true);
    if (!enabled) {
      this.log('info', 'Bluetooth is off: asking to turn it on');
      await client.requestEnable().catch(() => undefined);
      enabled = await client.isEnabled().catch(() => false);
      if (!enabled) throw new TransportError('unavailable', 'Bluetooth is off');
    }
    return client;
  }

  private async initialize(): Promise<BleClientApi> {
    const client = this.clientOverride ?? (await loadBleClient());
    this.log('info', 'initialising Bluetooth (asks for permission the first time)');
    // The app never derives a location from scans; AndroidManifest.xml
    // declares BLUETOOTH_SCAN with neverForLocation to match.
    await client.initialize({ androidNeverForLocation: true });
    try {
      await client.setDisplayStrings(chooserStrings(getLocale()));
    } catch (error) {
      this.log('warn', `chooser texts not set: ${describe(error)}`);
    }
    return client;
  }

  /**
   * Opens the native chooser. Android 11 and older find no Bluetooth devices
   * while Location is off, and the chooser then just stays empty until the
   * user cancels, so that case is reported before it opens.
   */
  private async choose(client: BleClientApi, signal: AbortSignal | undefined): Promise<BleDevice> {
    const version = this.androidVersion();
    const locationOff = async () =>
      version !== undefined && version >= 12 ? false : (await client.isLocationEnabled().catch(() => true)) === false;
    if (version !== undefined && version <= 11 && (await locationOff())) {
      throw new TransportError('unavailable', `choosing a device: ${LOCATION_OFF}`);
    }
    this.log('info', 'opening the device chooser');
    try {
      const device = await withAbort(client.requestDevice(requestDeviceOptions()), signal);
      this.log('info', `chose ${device.name ?? device.deviceId}`);
      return device;
    } catch (error) {
      let failure = toTransportError(error, 'choosing a device');
      // An empty chooser the user cancelled (or one that found nothing) may
      // still be Location; the Android version is not always known.
      const userGaveUp = failure.code === 'notFound' || (failure.code === 'cancelled' && !signal?.aborted);
      if (userGaveUp && (await locationOff())) {
        failure = new TransportError(failure.code, `${failure.message} (${LOCATION_OFF})`, { cause: error });
      }
      // A chooser closed without a pick needs the user: never report it as retryable.
      if (failure.retryable) throw new TransportError('cancelled', failure.message, { cause: error });
      throw failure;
    }
  }

  private async setUp(options: ConnectOptions): Promise<void> {
    const signal = options.signal;
    throwIfAborted(signal);
    const client = await this.ready();
    throwIfAborted(signal);
    const device = this.device ?? (await this.choose(client, signal));
    this.device = device;
    throwIfAborted(signal);

    const link = this.newLink(client, device.deviceId);
    const timeoutMs = options.timeoutMs ?? this.connectTimeoutMs;
    const pairingTimeoutMs = Math.max(timeoutMs, this.pairingTimeoutMs);
    const limit = (what: string, ms: number) =>
      setTimeout(() => this.fail(link, new TransportError('timeout', `${what} took longer than ${seconds(ms)}`)), ms);
    let timer = limit('connecting', timeoutMs);
    const onAbort = () => this.fail(link, new TransportError('cancelled', 'connecting was cancelled'));
    signal?.addEventListener('abort', onAbort, { once: true });
    /** The device accepted the connection: a drop from now on is the device's doing. */
    let accepted = false;
    try {
      this.log('info', `connecting to ${device.name ?? device.deviceId}`);
      await this.operation(
        link,
        'connect',
        async () => {
          await this.closing;
          await client.connect(device.deviceId, () => this.onPluginDisconnect(link), { timeout: timeoutMs });
        },
        timeoutMs,
      );
      accepted = true;
      const services = await this.operation(link, 'list the services', () => client.getServices(device.deviceId));
      if (!hasCharacteristic(services, SERVICE, CHAR_COMMAND) || !hasCharacteristic(services, SERVICE, CHAR_IMAGE)) {
        throw new TransportError('notFound', 'the chosen device does not offer the e-paper service');
      }
      for (const name of ['modelNumber', 'firmwareRevision'] as const) {
        if (hasCharacteristic(services, ...UUIDS[name])) link.readable.add(name);
      }
      if (link.readable.size < 2) this.log('warn', 'Device Information is incomplete on this device');
      link.mtu = await this.queryMtu(link);
      if (link.mtu !== undefined) this.log('info', `ATT MTU ${link.mtu}`);
      // The pairing prompt may appear now and wait for the user.
      clearTimeout(timer);
      timer = limit('enabling notifications (pairing included)', pairingTimeoutMs);
      await this.enableNotifications(link, 'command', pairingTimeoutMs);
      await this.enableNotifications(link, 'image', pairingTimeoutMs);
      if (link.error) throw link.error;
      link.up = true;
      this.lastWritten = undefined;
      this.log('info', 'connected, notifications on');
    } catch (error) {
      // A drop while enabling notifications keeps its mark (see duringPairing).
      const marked = error instanceof TransportError && error.duringPairing;
      let failure = marked ? error : (link.error ?? toTransportError(error, 'connecting'));
      // Only the plugin's disconnect callback tells that the link is down.
      if (accepted) failure = connectFailure(failure, link.error?.code !== 'linkLost');
      this.fail(link, failure);
      this.log('warn', failure.message);
      throw failure;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
    }
  }

  /**
   * Turn on notifications for `characteristic`. The first time, Android pairs
   * with the calendar here, so this may wait for the user.
   */
  private async enableNotifications(
    link: Link,
    characteristic: ProtocolCharacteristic,
    timeoutMs: number,
  ): Promise<void> {
    const [service, uuid] = UUIDS[characteristic];
    try {
      await this.operation(
        link,
        `enable ${characteristic} notifications`,
        () =>
          link.client.startNotifications(
            link.deviceId,
            service,
            uuid,
            (value) => this.deliver(link, characteristic, value),
            { timeout: timeoutMs },
          ),
        timeoutMs,
      );
    } catch (error) {
      const failure = link.error ?? toTransportError(error, `enabling ${characteristic} notifications`);
      // Both characteristics only accept an encrypted link: a refusal while
      // the link stays up means the pairing did not work; a drop here, every
      // time, usually means a stale pairing.
      throw notificationFailure(failure, link.error === undefined, failure.cause ?? error);
    }
  }

  private async queryMtu(link: Link): Promise<number | undefined> {
    try {
      const mtu = await link.client.getMtu(link.deviceId);
      return Number.isFinite(mtu) && mtu > ATT_HEADER ? mtu : undefined;
    } catch (error) {
      this.log('warn', `MTU unknown: ${describe(error)}`);
      return undefined;
    }
  }

  private newLink(client: BleClientApi, deviceId: string): Link {
    let reject!: (error: TransportError) => void;
    const gone = new Promise<never>((_, rejectGone) => {
      reject = rejectGone;
    });
    gone.catch(() => undefined);
    const link: Link = {
      client,
      deviceId,
      up: false,
      error: undefined,
      gone,
      reject,
      readable: new Set(),
      mtu: undefined,
    };
    this.link = link;
    return link;
  }

  /** The link is gone: fail everything pending on it, close it and tell the listeners. */
  private fail(link: Link, error: TransportError, reason: DisconnectReason = 'lost'): void {
    if (link.error) return;
    const wasUp = link.up;
    link.error = error;
    link.up = false;
    link.reject(error);
    if (this.link === link) {
      this.link = undefined;
      // Also aborts a connect still in progress. Already disconnected is fine.
      this.closing = link.client.disconnect(link.deviceId).catch(() => undefined);
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

  private onPluginDisconnect(link: Link): void {
    this.fail(link, new TransportError('linkLost', 'the device disconnected'));
  }

  // --- Operations -----------------------------------------------------------------

  private requireLink(): Link {
    const link = this.link;
    if (!link?.up) throw new TransportError('linkLost', 'not connected');
    return link;
  }

  /**
   * Run one GATT operation on `link` after every earlier one settled. It fails
   * with the link's error as soon as the link goes down, and with `timeout`
   * (dropping the link, whose GATT state is then unknown) after `timeoutMs`.
   */
  private operation<T>(
    link: Link,
    label: string,
    start: () => Promise<T>,
    timeoutMs: number = this.operationTimeoutMs,
  ): Promise<T> {
    const run = async (): Promise<T> => {
      if (link.error) throw link.error;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          const error = new TransportError('timeout', `${label}: no answer within ${seconds(timeoutMs)}`);
          reject(error);
          this.fail(link, error);
        }, timeoutMs);
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

  private writeMethod(characteristic: ProtocolCharacteristic, requested: WriteMode): WriteMode {
    if (characteristic === 'image' && this.writeMode !== 'auto') return this.writeMode;
    return requested;
  }

  // --- Notifications --------------------------------------------------------------

  private deliver(link: Link, characteristic: ProtocolCharacteristic, view: DataView): void {
    // Late notifications from an earlier link are not ours to report.
    if (this.link !== link || link.error) return;
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
 * A plugin error as a TransportError. The plugin rejects with plain messages
 * (and Capacitor with a `code` for missing implementations), so the message
 * decides.
 */
export function toTransportError(error: unknown, what: string): TransportError {
  if (error instanceof TransportError) return error;
  const code = typeof error === 'object' && error !== null && 'code' in error ? String(error.code) : '';
  const detail = describe(error);
  const message = `${what}: ${detail}`;
  const options = { cause: error };
  if (code === 'UNIMPLEMENTED' || code === 'UNAVAILABLE') return new TransportError('unsupported', message, options);
  if (/cancel/i.test(detail)) return new TransportError('cancelled', message, options);
  if (/permission/i.test(detail)) return new TransportError('unavailable', message, options);
  if (/not supported|unsupported|not available|not implemented/i.test(detail)) {
    return new TransportError('unsupported', message, options);
  }
  if (/not enabled|disabled|turned off|bluetooth is off|requestEnable/i.test(detail)) {
    return new TransportError('unavailable', message, options);
  }
  if (/timeout|timed out/i.test(detail)) return new TransportError('timeout', message, options);
  if (/bond|pair|auth|encrypt/i.test(detail)) return new TransportError('bondLost', message, options);
  if (/no device found/i.test(detail)) return new TransportError('notFound', message, options);
  return new TransportError('linkLost', message, options);
}

function hasCharacteristic(services: readonly BleService[], service: string, characteristic: string): boolean {
  const found = services.find((s) => sameUuid(s.uuid, service));
  return found?.characteristics.some((c) => sameUuid(c.uuid, characteristic)) === true;
}

function sameUuid(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

/** `promise`, or TransportError `cancelled` as soon as `signal` aborts. */
function withAbort<T>(promise: Promise<T>, signal: AbortSignal | undefined): Promise<T> {
  if (!signal) return promise;
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(new TransportError('cancelled', 'connecting was cancelled'));
    if (signal.aborted) onAbort();
    signal.addEventListener('abort', onAbort, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', onAbort));
  });
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) throw new TransportError('cancelled', 'connecting was cancelled');
}

function copyView(view: DataView): Uint8Array {
  return new Uint8Array(view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength));
}

function describe(error: unknown): string {
  if (error instanceof Error) return error.message || error.name;
  if (typeof error === 'object' && error !== null && 'message' in error) return String(error.message);
  return String(error);
}

function seconds(ms: number): string {
  return `${Number((ms / 1000).toFixed(1))} s`;
}
