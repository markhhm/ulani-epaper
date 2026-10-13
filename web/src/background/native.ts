/**
 * The page's side of the JavaScript bridge of the Android background sync (SyncBridge.java): the
 * service loads `background.html` in a WebView without a screen and adds `window.PaperhueSync`,
 * which does what the Capacitor plugins do in the app: Bluetooth GATT, the phone's calendar
 * query and HTTP. A call is `PaperhueSync.call(id, method, argsJson)`; Java later stores the answer
 * and calls `window.paperhueSync.settle(id)`, and the page takes it with `PaperhueSync.take(id)`
 * (`{"value": …}` or `{"error": "…"}`). Notifications and a dropped link arrive through
 * `window.paperhueSync.event({…})`. Bytes travel as hex.
 */

import type { BleClientInterface, BleDevice, BleService } from '@capacitor-community/bluetooth-le';
import type { BleClientApi } from '../ble/capacitorBle';
import type { CalendarHost, PhoneCalendars } from '../core/sources';

/** The object SyncBridge.java adds to the page. */
export interface SyncHost {
  call(id: string, method: string, args: string): void;
  take(id: string): string;
  /** The sync is over: `result` is a JSON BackgroundResult. */
  finish(result: string): void;
}

export type NativeEvent = { type: 'notify'; characteristic: string; value: string } | { type: 'disconnected' };

/** What the page sets up for Java to call into. */
export interface PageHooks {
  paperhueSync?: { settle(id: string): void; event(event: NativeEvent): void };
}

export class Native {
  private next = 0;
  private readonly pending = new Map<string, { resolve(value: unknown): void; reject(error: Error): void }>();
  private readonly listeners = new Set<(event: NativeEvent) => void>();

  constructor(
    private readonly host: SyncHost,
    page: PageHooks,
  ) {
    page.paperhueSync = {
      settle: (id) => this.settle(id),
      event: (event) => {
        for (const listener of [...this.listeners]) listener(event);
      },
    };
  }

  call<T>(method: string, args: object = {}): Promise<T> {
    const id = String(++this.next);
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
      this.host.call(id, method, JSON.stringify(args));
    });
  }

  onEvent(listener: (event: NativeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  finish(result: object): void {
    this.host.finish(JSON.stringify(result));
  }

  private settle(id: string): void {
    const waiting = this.pending.get(id);
    if (!waiting) return;
    this.pending.delete(id);
    const answer = JSON.parse(this.host.take(id)) as { value?: unknown; error?: string };
    if (answer.error !== undefined) waiting.reject(new Error(answer.error));
    else waiting.resolve(answer.value ?? null);
  }
}

const toHex = (view: DataView): string =>
  Array.from(new Uint8Array(view.buffer, view.byteOffset, view.byteLength), (b) => b.toString(16).padStart(2, '0')).join('');

function fromHex(hex: string): DataView {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return new DataView(bytes.buffer);
}

/**
 * The plugin's BleClient as CapacitorBleTransport uses it, over the bridge, for the device the app
 * connected to last (`deviceId`): no chooser, no permission prompts (the app asked for them).
 */
export function bridgeBleClient(native: Native, deviceId: string): BleClientApi {
  const notifications = new Map<string, (value: DataView) => void>();
  let dropped: ((deviceId: string) => void) | undefined;
  native.onEvent((event) => {
    if (event.type === 'notify') notifications.get(event.characteristic.toLowerCase())?.(fromHex(event.value));
    else dropped?.(deviceId);
  });
  const write = (withResponse: boolean): BleClientInterface['write'] => async (id, service, characteristic, value) => {
    await native.call('ble.write', { deviceId: id, service, characteristic, value: toHex(value), withResponse });
  };
  return {
    initialize: async () => undefined,
    isEnabled: () => native.call<boolean>('ble.isEnabled'),
    requestEnable: async () => {
      throw new Error('Bluetooth is off');
    },
    isLocationEnabled: async () => true, // no scan: the device is reached by its address
    setDisplayStrings: async () => undefined,
    requestDevice: async (): Promise<BleDevice> => ({ deviceId }),
    connect: async (id, onDisconnect, options) => {
      dropped = onDisconnect;
      await native.call('ble.connect', { deviceId: id, timeout: options?.timeout ?? 30_000 });
    },
    disconnect: async (id) => {
      await native.call('ble.disconnect', { deviceId: id });
    },
    getServices: (id) => native.call<BleService[]>('ble.services', { deviceId: id }),
    getMtu: (id) => native.call<number>('ble.getMtu', { deviceId: id }),
    startNotifications: async (id, service, characteristic, callback) => {
      notifications.set(characteristic.toLowerCase(), callback);
      await native.call('ble.notify', { deviceId: id, service, characteristic });
    },
    write: write(true),
    writeWithoutResponse: write(false),
    read: async (id, service, characteristic) => fromHex(await native.call<string>('ble.read', { deviceId: id, service, characteristic })),
  };
}

/** The phone's calendars and HTTP, through Android (CalendarContract, HttpURLConnection). */
export function nativeCalendarHost(native: Native): CalendarHost {
  return {
    phoneEvents: async (from, to) => (await native.call<PhoneCalendars | null>('calendar.events', { from, to })) ?? undefined,
    get: (url) => native.call<{ status: number; text: string }>('http.get', { url }),
  };
}
