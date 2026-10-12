/**
 * Picks the Bluetooth backend for the platform the code runs on: the native
 * plugin inside the Android app (Capacitor), Web Bluetooth in browsers.
 */

import { Capacitor } from '@capacitor/core';
import { CapacitorBleTransport } from './capacitorBle';
import type { Transport } from './transport';
import { WebBluetoothTransport } from './webBluetooth';

/** Whether the code runs inside the native app rather than a browser. */
export function isNativeApp(): boolean {
  return Capacitor.isNativePlatform();
}

/** A new, unconnected transport for this platform. */
export function createTransport(): Transport {
  return isNativeApp() ? new CapacitorBleTransport() : new WebBluetoothTransport();
}
