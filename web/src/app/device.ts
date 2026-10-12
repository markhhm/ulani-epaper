/**
 * The real device link for the model (browser or Android app): a Bluetooth transport and the session
 * on top of it. Call it straight from a tap: Web Bluetooth opens its chooser from that gesture.
 */

import { createTransport } from '../ble/select';
import { type LinkEvent, connectSession } from '../session/session';
import type { DeviceSession } from './model';

/** Choose (the first time) and connect to the device. */
export async function connectDevice(onLink: (event: LinkEvent) => void): Promise<DeviceSession> {
  const transport = createTransport();
  const session = await connectSession(transport, { attempts: 3, retryDelayMs: 3_000, onLink });
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
