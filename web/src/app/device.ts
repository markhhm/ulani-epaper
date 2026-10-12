/**
 * The real device link for the model (browser or Android app): a Bluetooth transport and the session
 * on top of it. Call connectDevice straight from a tap: Web Bluetooth opens its chooser from that gesture.
 */

import { createTransport } from '../ble/select';
import type { Transport } from '../ble/transport';
import { rememberedDevice, WebBluetoothTransport } from '../ble/webBluetooth';
import { type CalendarSession, type LinkEvent, connectSession } from '../session/session';
import type { DeviceSession } from './model';

function deviceSession(transport: Transport, session: CalendarSession): DeviceSession {
  return {
    get name() {
      return transport.deviceName;
    },
    get connected() {
      return transport.connected;
    },
    battery: () => session.battery(),
    currentSlot: () => session.currentSlot(),
    pushPages: (frames, options) => session.pushPages(frames, options),
    show: (slot) => session.show(slot),
    onDisconnect: (listener) => transport.onDisconnect(listener),
    close: () => session.close(),
  };
}

/** Choose (the first time) and connect to the device. */
export async function connectDevice(onLink: (event: LinkEvent) => void): Promise<DeviceSession> {
  const transport = createTransport();
  return deviceSession(transport, await connectSession(transport, { attempts: 3, retryDelayMs: 3_000, onLink }));
}

/**
 * Connect to the device the browser already knows, without a tap (the iPhone Shortcut opens the page
 * and nobody touches it): undefined when there is none. Tries for about a minute (the device is
 * not always in reach or listening), then throws ConnectFailed. `bluetooth` is for tests.
 */
export async function reconnectDevice(
  onLink: (event: LinkEvent) => void,
  signal: AbortSignal,
  bluetooth?: Bluetooth,
): Promise<DeviceSession | undefined> {
  const device = await rememberedDevice(bluetooth);
  if (!device) return undefined;
  const transport = new WebBluetoothTransport({ device, ...(bluetooth ? { bluetooth } : {}) });
  const session = await connectSession(transport, {
    attempts: 1,
    retryDelayMs: 3_000,
    attemptTimeoutMs: 12_000,
    connectWindowMs: 48_000,
    onLink,
    signal,
  });
  return deviceSession(transport, session);
}
