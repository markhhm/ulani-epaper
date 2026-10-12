import type {
  BleDevice,
  BleService,
  DisplayStrings,
  InitializeOptions,
  RequestBleDeviceOptions,
  TimeoutOptions,
} from '@capacitor-community/bluetooth-le';
import { describe, expect, it } from 'vitest';
import {
  androidVersionOf,
  type BleClientApi,
  CapacitorBleTransport,
  chooserStrings,
  requestDeviceOptions,
  toTransportError,
} from '../src/ble/capacitorBle';
import { type DisconnectReason, type TransportNotification, TransportError } from '../src/ble/transport';
import {
  ADVERTISED_SERVICE,
  CHAR_COMMAND,
  CHAR_FIRMWARE_REVISION,
  CHAR_IMAGE,
  CHAR_MODEL_NUMBER,
  DEVICE_INFORMATION_SERVICE,
  SERVICE,
} from '../src/core/protocol';

const CALENDAR: BleDevice = { deviceId: 'AA:BB:CC:DD:EE:FF', name: 'ULANI Calendar DDEEFF' };

function service(uuid: string, characteristics: readonly string[]): BleService {
  const properties = {
    broadcast: false,
    read: true,
    writeWithoutResponse: true,
    write: true,
    notify: true,
    indicate: false,
    authenticatedSignedWrites: false,
  };
  return { uuid, characteristics: characteristics.map((c) => ({ uuid: c, properties, descriptors: [] })) };
}

function calendarServices(): BleService[] {
  return [
    service(SERVICE.toUpperCase(), [CHAR_COMMAND, CHAR_IMAGE]),
    service(DEVICE_INFORMATION_SERVICE, [CHAR_MODEL_NUMBER, CHAR_FIRMWARE_REVISION]),
  ];
}

function bytesOf(view: DataView): number[] {
  return Array.from(new Uint8Array(view.buffer, view.byteOffset, view.byteLength));
}

interface PluginWrite {
  readonly characteristic: string;
  readonly bytes: number[];
  readonly withResponse: boolean;
}

/** The plugin's BleClient without Bluetooth: records calls, scripts results. */
class FakeBleClient implements BleClientApi {
  readonly calls: string[] = [];
  readonly writes: PluginWrite[] = [];
  readonly readValues = new Map<string, Uint8Array>();
  enabled = true;
  enableAllowed = false;
  locationEnabled = true;
  initializeError: Error | undefined;
  chooserResult: BleDevice | Error = CALENDAR;
  services: BleService[] = calendarServices();
  mtu = 247;
  notificationError: Error | undefined;
  /** The calendar drops the link when notifications are enabled (and the call fails). */
  dropOnNotify = false;
  /** Writes never complete. */
  hangWrites = false;
  /** Writes with response fail with this. */
  writeError: Error | undefined;
  initializeOptions: InitializeOptions | undefined;
  displayStrings: DisplayStrings | undefined;
  chooserOptions: RequestBleDeviceOptions | undefined;
  linkUp = false;

  private readonly callbacks = new Map<string, (value: DataView) => void>();
  private disconnected: ((deviceId: string) => void) | undefined;

  async initialize(options?: InitializeOptions): Promise<void> {
    this.calls.push('initialize');
    this.initializeOptions = options;
    if (this.initializeError) throw this.initializeError;
  }

  async isEnabled(): Promise<boolean> {
    return this.enabled;
  }

  async requestEnable(): Promise<void> {
    this.calls.push('requestEnable');
    if (!this.enableAllowed) throw new Error('requestEnable failed.');
    this.enabled = true;
  }

  async isLocationEnabled(): Promise<boolean> {
    return this.locationEnabled;
  }

  async setDisplayStrings(displayStrings: DisplayStrings): Promise<void> {
    this.displayStrings = displayStrings;
  }

  async requestDevice(options?: RequestBleDeviceOptions): Promise<BleDevice> {
    this.calls.push('requestDevice');
    this.chooserOptions = options;
    if (this.chooserResult instanceof Error) throw this.chooserResult;
    return this.chooserResult;
  }

  async connect(deviceId: string, onDisconnect?: (deviceId: string) => void): Promise<void> {
    this.calls.push(`connect ${deviceId}`);
    this.disconnected = onDisconnect;
    this.linkUp = true;
  }

  async disconnect(deviceId: string): Promise<void> {
    this.calls.push(`disconnect ${deviceId}`);
    // Like the plugin, report the link going down to the connect() listener.
    if (this.linkUp) this.drop();
  }

  async getServices(): Promise<BleService[]> {
    return this.services;
  }

  async getMtu(): Promise<number> {
    return this.mtu;
  }

  async startNotifications(
    _deviceId: string,
    serviceUuid: string,
    characteristic: string,
    callback: (value: DataView) => void,
  ): Promise<void> {
    this.calls.push(`notify ${characteristic}`);
    expect(serviceUuid).toBe(SERVICE);
    if (this.dropOnNotify) {
      this.drop();
      throw new Error('Not connected to device.');
    }
    if (this.notificationError) throw this.notificationError;
    this.callbacks.set(characteristic, callback);
  }

  write(_deviceId: string, _service: string, characteristic: string, value: DataView): Promise<void> {
    if (this.writeError) return Promise.reject(this.writeError);
    return this.record(characteristic, value, true);
  }

  writeWithoutResponse(_deviceId: string, _service: string, characteristic: string, value: DataView): Promise<void> {
    return this.record(characteristic, value, false);
  }

  async read(_deviceId: string, serviceUuid: string, characteristic: string, _options?: TimeoutOptions): Promise<DataView> {
    expect(serviceUuid).toBe(DEVICE_INFORMATION_SERVICE);
    return new DataView((this.readValues.get(characteristic) ?? new Uint8Array(0)).slice().buffer);
  }

  /** A notification from the calendar. */
  notify(characteristic: string, bytes: readonly number[]): void {
    this.callbacks.get(characteristic)?.(new DataView(Uint8Array.from(bytes).buffer));
  }

  /** The calendar drops the link. */
  drop(): void {
    this.linkUp = false;
    this.disconnected?.(CALENDAR.deviceId);
  }

  private record(characteristic: string, value: DataView, withResponse: boolean): Promise<void> {
    this.writes.push({ characteristic, bytes: bytesOf(value), withResponse });
    return this.hangWrites ? new Promise<void>(() => undefined) : Promise.resolve();
  }
}

function setUp(options: { operationTimeoutMs?: number; androidVersion?: () => number | undefined } = {}) {
  const client = new FakeBleClient();
  const transport = new CapacitorBleTransport({ client, ...options });
  const notifications: TransportNotification[] = [];
  const downs: DisconnectReason[] = [];
  transport.onNotification((n) => notifications.push(n));
  transport.onDisconnect((reason) => downs.push(reason));
  return { client, transport, notifications, downs };
}

describe('CapacitorBleTransport', () => {
  it('asks for permission, chooses the calendar, connects and enables both notifications', async () => {
    const { client, transport } = setUp();
    expect(transport.kind).toBe('capacitor-ble');
    expect(transport.connected).toBe(false);
    expect(await transport.maxWriteLength()).toBeUndefined();

    await transport.connect();

    expect(transport.connected).toBe(true);
    expect(transport.deviceName).toBe(CALENDAR.name);
    expect(client.initializeOptions).toEqual({ androidNeverForLocation: true });
    expect(client.displayStrings).toEqual(chooserStrings('zh-TW'));
    expect(client.chooserOptions).toEqual(requestDeviceOptions());
    expect(client.calls).toEqual([
      'initialize',
      'requestDevice',
      `connect ${CALENDAR.deviceId}`,
      `notify ${CHAR_COMMAND}`,
      `notify ${CHAR_IMAGE}`,
    ]);
    expect(await transport.maxWriteLength()).toBe(244);
  });

  it('filters the chooser on the advertised service and asks for the services it uses', () => {
    expect(requestDeviceOptions()).toEqual({
      services: [ADVERTISED_SERVICE],
      optionalServices: [SERVICE, DEVICE_INFORMATION_SERVICE],
    });
  });

  it('writes commands with response and image data without, as exactly the given bytes', async () => {
    const { client, transport } = setUp();
    await transport.connect();
    const frame = Uint8Array.of(9, 9, 1, 2, 3, 9);

    await transport.write('command', Uint8Array.of(0x04, 0x4e, 0x42), 'withResponse');
    await transport.write('image', frame.subarray(2, 5), 'withoutResponse');
    transport.writeMode = 'withResponse';
    await transport.write('image', frame.subarray(0, 2), 'withoutResponse');

    expect(client.writes).toEqual([
      { characteristic: CHAR_COMMAND, bytes: [0x04, 0x4e, 0x42], withResponse: true },
      { characteristic: CHAR_IMAGE, bytes: [1, 2, 3], withResponse: false },
      { characteristic: CHAR_IMAGE, bytes: [9, 9], withResponse: true },
    ]);
  });

  it('delivers notifications from both characteristics, in order', async () => {
    const { client, transport, notifications } = setUp();
    await transport.connect();

    client.notify(CHAR_COMMAND, [0x04, 0x00]);
    client.notify(CHAR_IMAGE, [0x02, 0x00]);

    expect(notifications).toEqual([
      { characteristic: 'command', value: Uint8Array.of(0x04, 0x00) },
      { characteristic: 'image', value: Uint8Array.of(0x02, 0x00) },
    ]);
  });

  it('reads Device Information, and reports it unsupported when the calendar lacks it', async () => {
    const { client, transport } = setUp();
    client.readValues.set(CHAR_FIRMWARE_REVISION, new TextEncoder().encode('1.0.7'));
    await transport.connect();
    expect(new TextDecoder().decode(await transport.read('firmwareRevision'))).toBe('1.0.7');

    const bare = setUp();
    bare.client.services = [service(SERVICE, [CHAR_COMMAND, CHAR_IMAGE])];
    await bare.transport.connect();
    await expect(bare.transport.read('modelNumber')).rejects.toMatchObject({ code: 'unsupported' });
  });

  it('reports a requested disconnect, then reconnects to the same calendar without the chooser', async () => {
    const { client, transport, downs } = setUp();
    await transport.connect();

    await transport.disconnect();
    expect(transport.connected).toBe(false);
    expect(downs).toEqual(['requested']);
    expect(client.calls).toContain(`disconnect ${CALENDAR.deviceId}`);
    await expect(transport.write('command', Uint8Array.of(1), 'withResponse')).rejects.toMatchObject({
      code: 'linkLost',
    });

    await transport.connect();
    expect(transport.connected).toBe(true);
    expect(client.calls.filter((call) => call === 'requestDevice')).toHaveLength(1);
    expect(client.calls.filter((call) => call === 'initialize')).toHaveLength(1);
  });

  it('fails pending writes and tells the listeners once when the calendar drops the link', async () => {
    const { client, transport, downs, notifications } = setUp();
    await transport.connect();
    client.hangWrites = true;

    const pending = transport.write('image', Uint8Array.of(1, 2), 'withoutResponse');
    client.drop();

    await expect(pending).rejects.toMatchObject({ code: 'linkLost' });
    expect(downs).toEqual(['lost']);
    client.notify(CHAR_COMMAND, [0x05, 0x00]);
    expect(notifications).toEqual([]);
    await transport.disconnect();
    expect(downs).toEqual(['lost']);
  });

  it('times out a stuck operation and drops the link', async () => {
    const { client, transport, downs } = setUp({ operationTimeoutMs: 20 });
    await transport.connect();
    client.hangWrites = true;

    await expect(transport.write('command', Uint8Array.of(1), 'withResponse')).rejects.toMatchObject({
      code: 'timeout',
    });
    expect(transport.connected).toBe(false);
    expect(downs).toEqual(['lost']);
  });

  it('reports a closed chooser as cancelled, never as retryable', async () => {
    const cancelled = setUp();
    cancelled.client.chooserResult = new Error('requestDevice cancelled.');
    await expect(cancelled.transport.connect()).rejects.toMatchObject({ code: 'cancelled' });

    const empty = setUp();
    empty.client.chooserResult = new Error('No device found.');
    empty.client.locationEnabled = false;
    const failure = await empty.transport.connect().catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(TransportError);
    expect(failure).toMatchObject({ code: 'cancelled', retryable: false });
    expect((failure as TransportError).message).toMatch(/location is off/);
  });

  it('asks for permission again on the next connect after it was denied', async () => {
    const { client, transport } = setUp();
    client.initializeError = new Error('Permission denied.');
    await expect(transport.connect()).rejects.toMatchObject({ code: 'unavailable' });

    client.initializeError = undefined;
    await transport.connect();
    expect(client.calls.filter((call) => call === 'initialize')).toHaveLength(2);
  });

  it('asks to turn Bluetooth on, and reports it off when the user declines', async () => {
    const declined = setUp();
    declined.client.enabled = false;
    await expect(declined.transport.connect()).rejects.toMatchObject({ code: 'unavailable' });
    expect(declined.client.calls).toContain('requestEnable');
    expect(declined.client.calls).not.toContain('requestDevice');

    const accepted = setUp();
    accepted.client.enabled = false;
    accepted.client.enableAllowed = true;
    await accepted.transport.connect();
    expect(accepted.transport.connected).toBe(true);
  });

  it('rejects a device without the calendar service and closes the link', async () => {
    const { client, transport } = setUp();
    client.services = [service(DEVICE_INFORMATION_SERVICE, [CHAR_MODEL_NUMBER])];
    await expect(transport.connect()).rejects.toMatchObject({ code: 'notFound' });
    expect(transport.connected).toBe(false);
    expect(client.calls).toContain(`disconnect ${CALENDAR.deviceId}`);
  });

  it('reports refused notifications on a live link as a pairing problem', async () => {
    const { client, transport, downs } = setUp();
    client.notificationError = new Error('Writing descriptor failed.');
    const error = await transport.connect().catch((e: unknown) => e);
    expect(error).toMatchObject({ code: 'bondLost' });
    expect((error as Error).message).toMatch(/hold its button about 5 s until the LED blinks green/);
    expect(transport.connected).toBe(false);
    // The link never came up, so nobody is told it went down.
    expect(downs).toEqual([]);
  });

  it('marks a link that drops while notifications are enabled (a stale pairing looks like this)', async () => {
    const { client, transport } = setUp();
    client.dropOnNotify = true;
    const error = await transport.connect().catch((e: unknown) => e);
    expect(error).toBeInstanceOf(TransportError);
    expect(error).toMatchObject({ code: 'linkLost', duringPairing: true, retryable: true });
  });

  it('marks a link the device drops while the services are listed (a device not in pairing mode does this)', async () => {
    const { client, transport, downs } = setUp();
    client.getServices = async () => {
      client.drop();
      throw new Error('Not connected to device.');
    };
    const error = await transport.connect().catch((e: unknown) => e);
    expect(error).toBeInstanceOf(TransportError);
    expect(error).toMatchObject({ code: 'linkLost', droppedWhileConnecting: true, duringPairing: false, retryable: true });
    expect(transport.connected).toBe(false);
    expect(downs).toEqual([]);
  });

  it('does not mark a failure while the link stays up', async () => {
    const { client, transport } = setUp();
    client.getServices = async () => {
      throw new Error('Discovering services failed.');
    };
    const error = await transport.connect().catch((e: unknown) => e);
    expect(error).toMatchObject({ code: 'linkLost', droppedWhileConnecting: false });
  });

  it('reports image data the calendar refuses with response as unsupported', async () => {
    const { client, transport } = setUp();
    await transport.connect();
    transport.writeMode = 'withResponse';
    client.writeError = new Error('Writing characteristic failed.');
    const error = await transport.write('image', Uint8Array.of(1), 'withoutResponse').catch((e: unknown) => e);
    expect(error).toMatchObject({ code: 'unsupported', retryable: false });
    expect((error as Error).message).toMatch(/does not accept image data written with response/);
    expect(transport.connected).toBe(true);
    // Commands keep the plain classification.
    expect(await transport.write('command', Uint8Array.of(6, 0), 'withResponse').catch((e: unknown) => e)).toMatchObject({
      code: 'linkLost',
    });
  });

  it('canRead follows the Device Information the calendar offers', async () => {
    const { client, transport } = setUp();
    expect(transport.canRead('firmwareRevision')).toBe(false);
    client.services = [service(SERVICE, [CHAR_COMMAND, CHAR_IMAGE]), service(DEVICE_INFORMATION_SERVICE, [CHAR_MODEL_NUMBER])];
    await transport.connect();
    expect(transport.canRead('modelNumber')).toBe(true);
    expect(transport.canRead('firmwareRevision')).toBe(false);
  });

  it('on Android 11 and older, reports Location off before opening an empty chooser', async () => {
    const old = setUp({ androidVersion: () => 11 });
    old.client.locationEnabled = false;
    const error = await old.transport.connect().catch((e: unknown) => e);
    expect(error).toMatchObject({ code: 'unavailable' });
    expect((error as Error).message).toMatch(/location is off/);
    expect(old.client.calls).not.toContain('requestDevice');

    old.client.locationEnabled = true;
    await old.transport.connect();
    expect(old.transport.connected).toBe(true);

    // Android 12 and later scan without Location.
    const recent = setUp({ androidVersion: () => 12 });
    recent.client.locationEnabled = false;
    await recent.transport.connect();
    expect(recent.transport.connected).toBe(true);
  });

  it('adds the Location hint when the user cancels an empty chooser on an unknown Android version', async () => {
    const { client, transport } = setUp({ androidVersion: () => undefined });
    client.locationEnabled = false;
    client.chooserResult = new Error('requestDevice cancelled.');
    const error = await transport.connect().catch((e: unknown) => e);
    expect(error).toMatchObject({ code: 'cancelled' });
    expect((error as Error).message).toMatch(/location is off/);

    client.locationEnabled = true;
    const plain = await transport.connect().catch((e: unknown) => e);
    expect((plain as Error).message).not.toMatch(/location/);
  });

  it('reads the Android version from the user agent', () => {
    expect(androidVersionOf('Mozilla/5.0 (Linux; Android 11; Pixel 3) AppleWebKit/537.36')).toBe(11);
    expect(androidVersionOf('Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 Version/4.0 Chrome/129')).toBe(14);
    expect(androidVersionOf('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)')).toBeUndefined();
  });

  it('cancels connecting when the signal aborts', async () => {
    const { transport } = setUp();
    const controller = new AbortController();
    controller.abort();
    await expect(transport.connect({ signal: controller.signal })).rejects.toMatchObject({ code: 'cancelled' });
  });
});

describe('toTransportError (plugin messages)', () => {
  it.each([
    ['requestDevice cancelled.', 'cancelled'],
    ['Pairing request was cancelled by the user.', 'cancelled'],
    ['Permission denied.', 'unavailable'],
    ['BLE is not supported.', 'unsupported'],
    ['BLE is not available.', 'unsupported'],
    ['Bluetooth not enabled.', 'unavailable'],
    ['Connection timeout.', 'timeout'],
    ['Write timeout.', 'timeout'],
    ['Creating bond failed.', 'bondLost'],
    ['No device found.', 'notFound'],
    ['Connection failed with status 133 (GATT_ERROR).', 'linkLost'],
    ['Writing characteristic failed.', 'linkLost'],
    ['Not connected to device.', 'linkLost'],
  ])('%s -> %s', (message, code) => {
    expect(toTransportError(new Error(message), 'x').code).toBe(code);
  });

  it('treats a missing native implementation as unsupported', () => {
    const error = Object.assign(new Error('not implemented on web'), { code: 'UNIMPLEMENTED' });
    expect(toTransportError(error, 'x').code).toBe('unsupported');
  });
});
