import { afterEach, describe, expect, it, vi } from 'vitest';
import { reconnectDevice } from '../../src/app/device';
import { rememberedDevice, WebBluetoothTransport } from '../../src/ble/webBluetooth';
import { ConnectFailed } from '../../src/session/session';
import { answerLikeACalendar, FakeBluetooth, FakeDevice } from './fakeWebBluetooth';

afterEach(() => vi.useRealTimers());

describe('the device this browser remembers', () => {
  it('is the device the browser let the page use before, if it lists any', async () => {
    const bluetooth = new FakeBluetooth();
    const device = bluetooth.device;
    expect(await rememberedDevice(bluetooth.api)).toBeUndefined();
    const other = new FakeDevice();
    other.name = 'Headphones';
    bluetooth.granted = [other, device];
    expect(await rememberedDevice(bluetooth.api)).toBe(device); // the one named like the device
    bluetooth.granted = [other];
    expect(await rememberedDevice(bluetooth.api)).toBe(other);
    expect(await rememberedDevice({ requestDevice: () => Promise.reject(new Error('x')) } as unknown as Bluetooth)).toBeUndefined(); // no getDevices
  });

  it('is connected to without the chooser when the transport is given it', async () => {
    const bluetooth = new FakeBluetooth();
    const transport = new WebBluetoothTransport({ bluetooth: bluetooth.api, device: bluetooth.device as unknown as BluetoothDevice });
    await transport.connect();
    expect(transport.connected).toBe(true);
    expect(transport.deviceName).toBe('ULANI Calendar 123456');
    expect(bluetooth.requests).toEqual([]);
  });
});

describe('reconnecting without a tap', () => {
  it('connects to the remembered device and unlocks it, never opening the chooser', async () => {
    const bluetooth = new FakeBluetooth();
    bluetooth.granted = [bluetooth.device];
    answerLikeACalendar(bluetooth.device);
    const session = await reconnectDevice(() => undefined, new AbortController().signal, bluetooth.api);
    expect(session?.connected).toBe(true);
    expect(session?.name).toBe('ULANI Calendar 123456');
    expect(bluetooth.requests).toEqual([]);
  });

  it('has nothing to connect to when the browser was never given a device', async () => {
    const bluetooth = new FakeBluetooth();
    expect(await reconnectDevice(() => undefined, new AbortController().signal, bluetooth.api)).toBeUndefined();
  });

  it('gives up after about a minute when the device does not answer', async () => {
    vi.useFakeTimers();
    const bluetooth = new FakeBluetooth();
    bluetooth.granted = [bluetooth.device];
    bluetooth.device.gatt.connectBehaviour = 'hang';
    const started = Date.now();
    let ended = 0;
    const result = reconnectDevice(() => undefined, new AbortController().signal, bluetooth.api).catch((error: unknown) => {
      ended = Date.now();
      return error;
    });
    await vi.advanceTimersByTimeAsync(120_000);
    expect(await result).toBeInstanceOf(ConnectFailed);
    expect(ended - started).toBeGreaterThanOrEqual(45_000);
    expect(ended - started).toBeLessThanOrEqual(60_000);
    expect(bluetooth.requests).toEqual([]);
  });
});
