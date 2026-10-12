import { describe, expect, it } from 'vitest';
import { createTransport } from '../src/ble/select';
import { connectFailure, type DisconnectReason, type TransportNotification, TransportError } from '../src/ble/transport';
import { DeviceError } from '../src/core/protocol';
import { FakeTransport } from './fakeTransport';

describe('createTransport', () => {
  it('returns an unconnected Web Bluetooth transport', () => {
    const transport = createTransport();
    expect(transport.kind).toBe('web-bluetooth');
    expect(transport.connected).toBe(false);
  });
});

describe('TransportError', () => {
  it('classifies what a new connection attempt can fix', () => {
    expect(new TransportError('linkLost', 'x').retryable).toBe(true);
    expect(new TransportError('notFound', 'x').retryable).toBe(true);
    expect(new TransportError('timeout', 'x').retryable).toBe(true);
    expect(new TransportError('bondLost', 'x').retryable).toBe(false);
    expect(new TransportError('cancelled', 'x').retryable).toBe(false);
    const error = new TransportError('unavailable', 'Bluetooth is off');
    expect(error).toBeInstanceOf(DeviceError);
    expect(error.name).toBe('TransportError');
  });
});

describe('connectFailure', () => {
  it('marks a link the device dropped after accepting the connection, and keeps it retryable', () => {
    const cause = new Error('GATT Server is disconnected.');
    const failure = connectFailure(new TransportError('linkLost', 'the device disconnected', { cause }), false);
    expect(failure.code).toBe('linkLost');
    expect(failure.message).toBe('the device disconnected');
    expect(failure.cause).toBe(cause);
    expect(failure.droppedWhileConnecting).toBe(true);
    expect(failure.duringPairing).toBe(false);
    expect(failure.retryable).toBe(true);
  });

  it('leaves other failures, and failures on a link that is still up, as they are', () => {
    const timeout = new TransportError('timeout', 'connecting took longer than 15 s');
    expect(connectFailure(timeout, false)).toBe(timeout);
    expect(timeout.droppedWhileConnecting).toBe(false);
    const refused = new TransportError('linkLost', 'find the e-paper service: failed');
    expect(connectFailure(refused, true)).toBe(refused);
    expect(refused.droppedWhileConnecting).toBe(false);
  });

  it('counts a drop while enabling notifications as a drop while connecting', () => {
    const error = new TransportError('linkLost', 'the device disconnected', { duringPairing: true });
    expect(error.droppedWhileConnecting).toBe(true);
    expect(connectFailure(error, false)).toBe(error);
  });
});

describe('FakeTransport', () => {
  it('records writes, scripts replies and reports a dropped link', async () => {
    const fake = new FakeTransport();
    const seen: TransportNotification[] = [];
    const downs: DisconnectReason[] = [];
    fake.onNotification((n) => seen.push(n));
    fake.onDisconnect((reason) => downs.push(reason));
    fake.respond = (write, f) => {
      if (write.characteristic === 'command') f.notify('command', [write.data[0] ?? 0, 0x00]);
    };

    await expect(fake.write('command', Uint8Array.of(0x04), 'withResponse')).rejects.toBeInstanceOf(TransportError);
    await fake.connect();
    await fake.write('command', Uint8Array.of(0x04, 0x4e, 0x42), 'withResponse');
    expect(fake.writes).toHaveLength(1);
    expect(seen).toEqual([{ characteristic: 'command', value: Uint8Array.of(0x04, 0x00) }]);

    fake.drop();
    expect(fake.connected).toBe(false);
    expect(downs).toEqual(['lost']);
  });
});
