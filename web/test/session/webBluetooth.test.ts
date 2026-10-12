import { afterEach, describe, expect, it, vi } from 'vitest';
import { type DisconnectReason, type LogEntry, TransportError, type TransportNotification } from '../../src/ble/transport';
import {
  DEFAULT_CONNECT_TIMEOUT_MS,
  DEFAULT_OPERATION_TIMEOUT_MS,
  DEFAULT_WRITE_LENGTH,
  hasWebBluetooth,
  requestDeviceOptions,
  toTransportError,
  WebBluetoothTransport,
  type WebBluetoothOptions,
} from '../../src/ble/webBluetooth';
import {
  ADVERTISED_SERVICE,
  CHAR_COMMAND,
  CHAR_FIRMWARE_REVISION,
  CHAR_IMAGE,
  DEVICE_INFORMATION_SERVICE,
  SERVICE,
} from '../../src/core/protocol';
import { ConnectFailed, connectSession } from '../../src/session/session';
import { answerLikeACalendar, FakeBluetooth, type FakeCharacteristic, FakeDevice } from './fakeWebBluetooth';

function setUp(options: Omit<WebBluetoothOptions, 'bluetooth'> = {}, device = new FakeDevice()) {
  const bluetooth = new FakeBluetooth(device);
  const transport = new WebBluetoothTransport({ ...options, bluetooth: bluetooth.api });
  return { bluetooth, device, transport };
}

async function connected(options: Omit<WebBluetoothOptions, 'bluetooth'> = {}, device = new FakeDevice()) {
  const parts = setUp(options, device);
  await parts.transport.connect();
  return parts;
}

async function rejection(promise: Promise<unknown>): Promise<TransportError> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(TransportError);
    return error as TransportError;
  }
  throw new Error('expected a rejection');
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('hasWebBluetooth', () => {
  it('follows navigator.bluetooth', () => {
    vi.stubGlobal('navigator', {});
    expect(hasWebBluetooth()).toBe(false);
    vi.stubGlobal('navigator', { bluetooth: new FakeBluetooth() });
    expect(hasWebBluetooth()).toBe(true);
  });
});

describe('connect', () => {
  it('opens the chooser at once with the calendar filter, then enables both notifications', async () => {
    const { bluetooth, device, transport } = setUp();
    const connecting = transport.connect();
    // Synchronous: nothing may be awaited before the chooser opens (user gesture).
    expect(bluetooth.requests).toHaveLength(1);
    expect(bluetooth.requests[0]).toEqual({
      filters: [{ services: [ADVERTISED_SERVICE] }, { namePrefix: 'ULANI' }],
      optionalServices: [SERVICE, DEVICE_INFORMATION_SERVICE],
    });
    expect(requestDeviceOptions()).toEqual(bluetooth.requests[0]);
    await connecting;
    expect(transport.connected).toBe(true);
    expect(transport.deviceName).toBe('ULANI Calendar 123456');
    expect(device.command.notifying && device.image.notifying).toBe(true);
    expect(device.log.slice(-2)).toEqual([`notify ${CHAR_COMMAND}`, `notify ${CHAR_IMAGE}`]);
    await transport.connect(); // already up: nothing happens
    expect(device.gatt.connectCalls).toBe(1);
  });

  it('reports a browser without Web Bluetooth as unsupported', async () => {
    vi.stubGlobal('navigator', {});
    const error = await rejection(new WebBluetoothTransport().connect());
    expect(error.code).toBe('unsupported');
  });

  it('reports a closed chooser as cancelled', async () => {
    const { bluetooth, transport } = setUp();
    bluetooth.chooser = new DOMException('User cancelled the requestDevice() chooser.', 'NotFoundError');
    const error = await rejection(transport.connect());
    expect(error.code).toBe('cancelled');
    expect(error.retryable).toBe(false);
  });

  it('never reports a chooser failure as retryable (a retry could not reopen it)', async () => {
    const { bluetooth, transport } = setUp();
    bluetooth.chooser = new DOMException('No devices found.', 'NotFoundError');
    const failed = await rejection(connectSession(transport, { retryDelayMs: 0 }));
    expect(failed.code).toBe('cancelled');
    expect(bluetooth.requests).toHaveLength(1);
    bluetooth.chooser = new DOMException('Bluetooth adapter not available.', 'NotFoundError');
    expect((await rejection(transport.connect())).code).toBe('unavailable');
  });

  it('reports a refused pairing as bondLost and closes the link', async () => {
    const { device, transport } = setUp();
    device.failures.set(`notify ${CHAR_COMMAND}`, new DOMException('GATT Error: Not paired.', 'NetworkError'));
    const error = await rejection(transport.connect());
    expect(error.code).toBe('bondLost');
    expect(transport.connected).toBe(false);
    expect(device.gatt.connected).toBe(false);
  });

  it('reports a device without the calendar service as notFound', async () => {
    const device = new FakeDevice();
    device.services.delete(SERVICE);
    const { transport } = setUp({}, device);
    const error = await rejection(transport.connect());
    expect(error.code).toBe('notFound');
    expect(error.message).toMatch(/^find the e-paper service: No Services matching UUID/);
  });

  it('works without Device Information, whose reads then fail as unsupported', async () => {
    const entries: LogEntry[] = [];
    const { transport } = await connected({ log: (e) => entries.push(e) }, new FakeDevice({ deviceInformation: false }));
    expect(transport.connected).toBe(true);
    expect((await rejection(transport.read('modelNumber'))).code).toBe('unsupported');
    expect(entries.some((e) => e.level === 'warn' && e.message.startsWith('Device Information unavailable'))).toBe(
      true,
    );
  });

  it('times out when the calendar does not take the connection, and aborts the attempt', async () => {
    vi.useFakeTimers();
    const { device, transport } = setUp({ connectTimeoutMs: 20_000 });
    device.gatt.connectBehaviour = 'hang';
    const outcome = rejection(transport.connect());
    await vi.advanceTimersByTimeAsync(20_000);
    const error = await outcome;
    expect(error.code).toBe('timeout');
    expect(error.message).toBe('connecting took longer than 20 s');
    expect(device.gatt.disconnectCalls).toBe(1);
  });

  it('takes the timeout from the options and stops when the signal aborts', async () => {
    vi.useFakeTimers();
    const { device, transport } = setUp();
    device.gatt.connectBehaviour = 'hang';
    const timedOut = rejection(transport.connect({ timeoutMs: 500 }));
    await vi.advanceTimersByTimeAsync(500);
    expect((await timedOut).code).toBe('timeout');

    const controller = new AbortController();
    const cancelled = rejection(transport.connect({ signal: controller.signal }));
    await vi.advanceTimersByTimeAsync(100);
    controller.abort();
    expect((await cancelled).code).toBe('cancelled');
  });

  it('gives connecting and enabling notifications the connect timeout (a pairing prompt waits for the user)', async () => {
    vi.useFakeTimers();
    expect(DEFAULT_CONNECT_TIMEOUT_MS).toBe(60_000);
    expect(DEFAULT_OPERATION_TIMEOUT_MS).toBe(30_000);
    const { device, transport } = setUp();
    // The pairing prompt: notifications come on only after 45 s.
    Object.assign(device.command, {
      startNotifications: () =>
        new Promise<FakeCharacteristic>((resolve) =>
          setTimeout(() => {
            device.command.notifying = true;
            resolve(device.command);
          }, 45_000),
        ),
    });
    const connecting = transport.connect();
    await vi.advanceTimersByTimeAsync(45_000);
    await connecting;
    expect(transport.connected).toBe(true);
  });

  it('still times out the whole connect after the connect timeout', async () => {
    vi.useFakeTimers();
    const { device, transport } = setUp();
    Object.assign(device.command, { startNotifications: () => new Promise<never>(() => undefined) });
    const outcome = rejection(transport.connect());
    await vi.advanceTimersByTimeAsync(60_000);
    const error = await outcome;
    expect(error.code).toBe('timeout');
    expect(device.gatt.connected).toBe(false);
  });

  it('reports notifications refused on a live link as bondLost, with the steps to pair again', async () => {
    const { device, transport } = setUp();
    device.failures.set(
      `notify ${CHAR_COMMAND}`,
      new DOMException('GATT operation failed for unknown reason.', 'NetworkError'),
    );
    const error = await rejection(transport.connect());
    expect(error.code).toBe('bondLost');
    expect(error.retryable).toBe(false);
    expect(error.message).toMatch(/hold its button about 5 s until the LED blinks green/);
    expect(device.gatt.connected).toBe(false);
  });

  it('marks a link that drops while notifications are enabled, and keeps it retryable', async () => {
    const { device, transport } = setUp();
    Object.assign(device.command, {
      startNotifications: () => {
        device.gatt.drop();
        return Promise.reject(
          new DOMException('GATT Server is disconnected. Cannot perform GATT operations.', 'NetworkError'),
        );
      },
    });
    const error = await rejection(transport.connect());
    expect(error.code).toBe('linkLost');
    expect(error.duringPairing).toBe(true);
    expect(error.retryable).toBe(true);
  });

  it('treats a failed call as a drop when the server is gone before its disconnect event', async () => {
    const { device, transport } = setUp();
    Object.assign(device.command, {
      startNotifications: () => {
        device.gatt.connected = false; // the event would follow later
        return Promise.reject(new DOMException('GATT operation failed for unknown reason.', 'NetworkError'));
      },
    });
    const error = await rejection(transport.connect());
    expect(error.code).toBe('linkLost');
    expect(error.duringPairing).toBe(true);
  });

  it('ends with a hint to pair again when every attempt drops while notifications are enabled', async () => {
    const { device, transport } = setUp();
    Object.assign(device.command, {
      startNotifications: () => {
        device.gatt.drop();
        return Promise.reject(
          new DOMException('GATT Server is disconnected. Cannot perform GATT operations.', 'NetworkError'),
        );
      },
    });
    const error = await connectSession(transport, { attempts: 2, retryDelayMs: 0 }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ConnectFailed);
    expect((error as ConnectFailed).stalePairing).toBe(true);
    expect((error as Error).message).toMatch(/stale pairing: forget the device/);
    expect(device.gatt.connectCalls).toBe(2);
  });

  it('marks a link the device drops while the services are found (a device not in pairing mode does this)', async () => {
    const { device, transport } = setUp();
    const find = device.gatt.getPrimaryService.bind(device.gatt);
    device.gatt.getPrimaryService = (uuid: string) => {
      device.gatt.drop();
      return find(uuid);
    };
    const error = await rejection(transport.connect());
    expect(error.code).toBe('linkLost');
    expect(error.droppedWhileConnecting).toBe(true);
    expect(error.duringPairing).toBe(false);
    expect(error.retryable).toBe(true);
    expect(transport.connected).toBe(false);
  });

  it('does not mark a connection the device never accepted', async () => {
    const { device, transport } = setUp();
    device.gatt.connectBehaviour = new DOMException('Bluetooth Device is no longer in range.', 'NetworkError');
    const error = await rejection(transport.connect());
    expect(error.code).toBe('linkLost');
    expect(error.droppedWhileConnecting).toBe(false);
  });

  it('ends with the pairing-mode hint when the device drops every attempt while connecting', async () => {
    const { device, transport } = setUp();
    const find = device.gatt.getPrimaryService.bind(device.gatt);
    device.gatt.getPrimaryService = (uuid: string) => {
      device.gatt.drop();
      return find(uuid);
    };
    const error = await connectSession(transport, { attempts: 2, retryDelayMs: 0 }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ConnectFailed);
    expect((error as ConnectFailed).droppedWhileConnecting).toBe(true);
    expect((error as ConnectFailed).stalePairing).toBe(false);
    expect((error as Error).message).toContain('(pairing mode), then connect again');
    expect(device.gatt.connectCalls).toBe(2);
  });

  it('tries a flaky Device Information discovery once more, but not a missing one', async () => {
    const device = new FakeDevice();
    device.failures.set(
      `service ${DEVICE_INFORMATION_SERVICE}`,
      new DOMException('GATT operation failed for unknown reason.', 'NetworkError'),
    );
    const { transport } = await connected({}, device);
    expect(device.log.filter((label) => label === `service ${DEVICE_INFORMATION_SERVICE}`)).toHaveLength(2);
    expect(transport.canRead('firmwareRevision')).toBe(true);
    expect(new TextDecoder().decode(await transport.read('firmwareRevision'))).toBe('v1.0.09');

    const bare = new FakeDevice({ deviceInformation: false });
    const other = await connected({}, bare);
    expect(bare.log.filter((label) => label === `service ${DEVICE_INFORMATION_SERVICE}`)).toHaveLength(1);
    expect(other.transport.canRead('firmwareRevision')).toBe(false);
  });

  it('canRead is false while not connected', async () => {
    const { transport } = setUp();
    expect(transport.canRead('modelNumber')).toBe(false);
    await transport.connect();
    expect(transport.canRead('modelNumber')).toBe(true);
    await transport.disconnect();
    expect(transport.canRead('modelNumber')).toBe(false);
  });

  it('shares one attempt between overlapping calls', async () => {
    const { bluetooth, device, transport } = setUp();
    await Promise.all([transport.connect(), transport.connect()]);
    expect(bluetooth.requests).toHaveLength(1);
    expect(device.gatt.connectCalls).toBe(1);
  });
});

describe('writeMethods', () => {
  it('reports the write methods of the real characteristic, once connected', async () => {
    // Bluefy exposes no global BluetoothRemoteGATTCharacteristic, but its
    // characteristic objects have the methods: only the real one tells.
    const { device, transport } = setUp();
    expect(transport.writeMethods('image')).toBeUndefined();
    await transport.connect();
    expect(transport.writeMethods('image')).toEqual({
      writeValueWithoutResponse: true,
      writeValueWithResponse: true,
      writeValue: true,
    });
    Object.assign(device.image, { writeValueWithoutResponse: undefined });
    expect(transport.writeMethods('image')).toEqual({
      writeValueWithoutResponse: false,
      writeValueWithResponse: true,
      writeValue: true,
    });
    await transport.disconnect();
    expect(transport.writeMethods('image')).toBeUndefined();
  });
});

describe('operations', () => {
  it('serialises concurrent GATT operations', async () => {
    const { device, transport } = await connected();
    const packets = Array.from({ length: 8 }, (_, i) => Uint8Array.of(i, i));
    await Promise.all([
      transport.write('command', Uint8Array.of(0x06, 0x00), 'withResponse'),
      ...packets.map((packet) => transport.write('image', packet, 'withoutResponse')),
      transport.read('firmwareRevision'),
      transport.read('modelNumber'),
    ]);
    expect(device.maxInFlight).toBe(1);
    expect(device.image.written.map((w) => w.bytes)).toEqual(packets);
  });

  it('writes commands with response and image data without response', async () => {
    const { device, transport } = await connected();
    await transport.write('command', Uint8Array.of(0x06, 0x00), 'withResponse');
    await transport.write('image', Uint8Array.of(1, 2, 3), 'withoutResponse');
    expect(device.command.written.map((w) => w.method)).toEqual(['writeValueWithResponse']);
    expect(device.image.written.map((w) => w.method)).toEqual(['writeValueWithoutResponse']);
  });

  it('falls back to writeValue where the dedicated methods are missing', async () => {
    const device = new FakeDevice();
    for (const characteristic of [device.command, device.image]) {
      Object.assign(characteristic, { writeValueWithResponse: undefined, writeValueWithoutResponse: undefined });
    }
    const { transport } = await connected({}, device);
    await transport.write('command', Uint8Array.of(0x06, 0x00), 'withResponse');
    await transport.write('image', Uint8Array.of(1), 'withoutResponse');
    expect([...device.command.written, ...device.image.written].map((w) => w.method)).toEqual([
      'writeValue',
      'writeValue',
    ]);
  });

  it('uses the configured write mode for image data only', async () => {
    const { device, transport } = await connected({ writeMode: 'withResponse' });
    await transport.write('image', Uint8Array.of(1), 'withoutResponse');
    await transport.write('command', Uint8Array.of(0x06, 0x00), 'withResponse');
    expect(device.image.written.map((w) => w.method)).toEqual(['writeValueWithResponse']);
    expect(device.command.written.map((w) => w.method)).toEqual(['writeValueWithResponse']);

    transport.writeMode = 'withoutResponse';
    Object.assign(device.image, { writeValueWithoutResponse: undefined });
    const error = await rejection(transport.write('image', Uint8Array.of(2), 'withoutResponse'));
    expect(error.code).toBe('unsupported');
    expect(error.message).toBe('this browser has no writeValueWithoutResponse');
  });

  it('reports image data the calendar refuses with response as unsupported, not as a dropped link', async () => {
    const { device, transport } = await connected({ writeMode: 'withResponse' });
    Object.assign(device.image, {
      writeValueWithResponse: () => Promise.reject(new DOMException('GATT operation not permitted.', 'NotSupportedError')),
    });
    const error = await rejection(transport.write('image', Uint8Array.of(1), 'withoutResponse'));
    expect(error.code).toBe('unsupported');
    expect(error.retryable).toBe(false);
    expect(error.message).toMatch(/does not accept image data written with response/);
    expect(transport.connected).toBe(true);

    // A generic failure of the same write while the link stays up is the same refusal.
    Object.assign(device.image, {
      writeValueWithResponse: () =>
        Promise.reject(new DOMException('GATT operation failed for unknown reason.', 'NetworkError')),
    });
    expect((await rejection(transport.write('image', Uint8Array.of(1), 'withoutResponse'))).code).toBe('unsupported');
  });

  it('writes an exact copy of a view into a larger buffer', async () => {
    const { device, transport } = await connected();
    const frame = Uint8Array.from({ length: 1000 }, (_, i) => i & 0xff);
    await transport.write('image', frame.subarray(180, 360), 'withoutResponse');
    const [written] = device.image.written;
    expect(written?.bytes).toEqual(frame.slice(180, 360));
    expect(written?.bufferLength).toBe(180);
  });

  it('reads characteristic values', async () => {
    const { transport } = await connected();
    expect(new TextDecoder().decode(await transport.read('firmwareRevision'))).toBe('v1.0.09');
    expect(new TextDecoder().decode(await transport.read('modelNumber'))).toBe('P7320E-B');
  });

  it('fails reads and writes while not connected', async () => {
    const { transport } = setUp();
    expect((await rejection(transport.write('command', Uint8Array.of(4), 'withResponse'))).code).toBe('linkLost');
    expect((await rejection(transport.read('firmwareRevision'))).code).toBe('linkLost');
  });

  it('times out a hung operation and drops the link', async () => {
    vi.useFakeTimers();
    const { device, transport } = await connected({ operationTimeoutMs: 10_000 });
    const downs: DisconnectReason[] = [];
    transport.onDisconnect((reason) => downs.push(reason));
    device.hold();
    const outcome = rejection(transport.write('command', Uint8Array.of(0x06, 0x00), 'withResponse'));
    await vi.advanceTimersByTimeAsync(10_000);
    const error = await outcome;
    expect(error.code).toBe('timeout');
    expect(error.message).toBe('write command: no answer within 10 s');
    expect(transport.connected).toBe(false);
    expect(device.gatt.connected).toBe(false);
    expect(downs).toEqual(['lost']);
  });

  it('maxWriteLength reports writeLength, 180 by default', async () => {
    expect(DEFAULT_WRITE_LENGTH).toBe(180);
    const { transport } = setUp();
    expect(await transport.maxWriteLength()).toBe(180);
    transport.writeLength = 100;
    expect(await transport.maxWriteLength()).toBe(100);
    expect(await new WebBluetoothTransport({ writeLength: 240 }).maxWriteLength()).toBe(240);
  });
});

describe('notifications', () => {
  it('delivers copies from both characteristics until unsubscribed', async () => {
    const { device, transport } = await connected();
    const seen: TransportNotification[] = [];
    const unsubscribe = transport.onNotification((n) => seen.push(n));
    device.command.emit([0x04, 0x00]);
    device.image.emit([0x02, 0x00]);
    expect(seen).toEqual([
      { characteristic: 'command', value: Uint8Array.of(0x04, 0x00) },
      { characteristic: 'image', value: Uint8Array.of(0x02, 0x00) },
    ]);
    expect(seen[0]?.value.buffer).not.toBe(device.command.value?.buffer);
    unsubscribe();
    unsubscribe();
    device.command.emit([0x05, 0x00]);
    expect(seen).toHaveLength(2);
  });

  it('keeps going when a listener throws', async () => {
    const { device, transport } = await connected();
    const seen: number[] = [];
    transport.onNotification(() => {
      throw new Error('listener bug');
    });
    transport.onNotification((n) => seen.push(n.value[0] ?? -1));
    device.command.emit([0x04, 0x00]);
    expect(seen).toEqual([0x04]);
  });
});

describe('disconnects', () => {
  it('fails in-flight and queued work at once, then reconnects without the chooser', async () => {
    const { bluetooth, device, transport } = await connected();
    const downs: DisconnectReason[] = [];
    transport.onDisconnect((reason) => downs.push(reason));
    device.hold();
    const inFlight = rejection(transport.write('command', Uint8Array.of(0x06, 0x00), 'withResponse'));
    const queued = rejection(transport.read('firmwareRevision'));
    await Promise.resolve();
    device.gatt.drop();
    for (const error of [await inFlight, await queued]) {
      expect(error.code).toBe('linkLost');
      expect(error.message).toBe('the device disconnected');
    }
    expect(downs).toEqual(['lost']);
    expect(transport.connected).toBe(false);

    await transport.connect();
    expect(bluetooth.requests).toHaveLength(1);
    expect(device.gatt.connectCalls).toBe(2);
    const seen: TransportNotification[] = [];
    transport.onNotification((n) => seen.push(n));
    device.command.emit([0x05, 0x00]);
    expect(seen).toHaveLength(1); // listeners were not added twice
    await transport.write('command', Uint8Array.of(0x04, 0x4e, 0x42), 'withResponse');
  });

  it('reports disconnect() as requested and never rejects', async () => {
    const { device, transport } = await connected();
    const downs: DisconnectReason[] = [];
    transport.onDisconnect((reason) => downs.push(reason));
    await transport.disconnect();
    await transport.disconnect();
    expect(downs).toEqual(['requested']);
    expect(device.gatt.connected).toBe(false);
    expect((await rejection(transport.write('command', Uint8Array.of(4), 'withResponse'))).message).toBe(
      'not connected',
    );
  });

  it('forget() makes the next connect open the chooser again', async () => {
    const { bluetooth, transport } = await connected();
    await transport.forget();
    await transport.connect();
    expect(bluetooth.requests).toHaveLength(2);
  });
});

describe('with the session', () => {
  it('unlocks only after both notifications are on, then uploads', async () => {
    const device = new FakeDevice();
    answerLikeACalendar(device);
    const entries: LogEntry[] = [];
    const log = (entry: LogEntry) => entries.push(entry);
    const { transport } = setUp({ log }, device);
    const session = await connectSession(transport, { log });
    const firstWrite = device.log.findIndex((label) => label.startsWith('write'));
    expect(device.log.indexOf(`notify ${CHAR_COMMAND}`)).toBeLessThan(firstWrite);
    expect(device.log.indexOf(`notify ${CHAR_IMAGE}`)).toBeLessThan(firstWrite);
    expect(device.command.written[0]?.bytes).toEqual(Uint8Array.of(0x04, 0x4e, 0x42));

    expect(await session.battery()).toEqual({ level: 5, charging: false });
    const frame = Uint8Array.from({ length: 5000 }, (_, i) => (i * 13) & 0xff);
    expect(await session.pushPages(new Map([[2, frame]]))).toEqual(new Map([[2, 'ok']]));
    const packets = device.image.written;
    expect(packets.map((w) => w.bytes.length)).toEqual([...Array(27).fill(180), 5000 - 27 * 180]);
    expect(Uint8Array.from(packets.flatMap((w) => [...w.bytes]))).toEqual(frame);
    expect(device.log.filter((label) => label === `read ${CHAR_FIRMWARE_REVISION}`)).toHaveLength(2);

    // Diagnostics: timestamps, both sources, and never more than a short preview of bytes.
    expect(entries.every((e) => typeof e.time === 'number' && e.time > 0)).toBe(true);
    expect(new Set(entries.map((e) => e.source))).toEqual(new Set(['web-bluetooth', 'session']));
    expect(entries.filter((e) => e.message.startsWith('image data:'))).toHaveLength(1);
    expect(Math.max(...entries.map((e) => e.message.length))).toBeLessThan(160);
    await session.close();
    expect(transport.connected).toBe(false);
  });
});

describe('toTransportError', () => {
  it.each([
    ['NotFoundError', 'User cancelled the requestDevice() chooser.', 'cancelled'],
    ['NotFoundError', 'Bluetooth adapter not available.', 'unavailable'],
    ['NotFoundError', 'No Services matching UUID found in Device.', 'notFound'],
    ['NotAllowedError', 'Permission denied.', 'unavailable'],
    ['SecurityError', 'Must be handling a user gesture to show a permission request.', 'unavailable'],
    ['NetworkError', 'GATT Server is disconnected. Cannot perform GATT operations.', 'linkLost'],
    ['NetworkError', 'GATT operation failed due to insufficient authentication.', 'bondLost'],
    ['NotSupportedError', 'GATT Error: Not paired.', 'bondLost'],
    ['NotSupportedError', 'GATT operation not permitted.', 'unsupported'],
    ['NetworkError', 'GATT Error: Not supported.', 'unsupported'],
    ['InvalidStateError', 'GATT Server is disconnected. Cannot retrieve services.', 'linkLost'],
    ['TimeoutError', 'Timed out.', 'timeout'],
  ])('%s "%s" -> %s', (name, message, code) => {
    const error = toTransportError(new DOMException(message, name), 'doing it');
    expect(error.code).toBe(code);
    expect(error.message).toBe(`doing it: ${message}`);
  });

  it('keeps TransportErrors as they are', () => {
    const original = new TransportError('timeout', 'x');
    expect(toTransportError(original, 'y')).toBe(original);
  });
});
