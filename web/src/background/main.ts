/**
 * Entry of background.html: one scheduled sync of the Android app, in the WebView that
 * SyncService.java runs without a screen. It reuses the app's storage (the page plan, the device
 * and iCal addresses the app remembered), drawing and device session; Bluetooth, the phone's
 * calendars and HTTP come through the service's JavaScript bridge (native.ts). The result goes
 * back to the service, which retries or logs it.
 */

import { CapacitorBleTransport } from '../ble/capacitorBle';
import { localZone } from '../core/agenda';
import { readCalendar } from '../core/sources';
import { connectSession } from '../session/session';
import { loadFeeds, rememberedDevice } from '../app/android';
import { drawCalendar } from '../app/calendar';
import { deviceSession } from '../app/device';
import { openIdbStore } from '../app/idbStore';
import { AppModel } from '../app/model';
import { bridgeBleClient, Native, nativeCalendarHost, type PageHooks, type SyncHost } from './native';
import { backgroundSync } from './sync';

async function run(native: Native): Promise<void> {
  const deviceId = rememberedDevice();
  const model = new AppModel({
    store: await openIdbStore(),
    drawCard: () => Promise.reject(new Error('the background sync draws calendar pages only')),
    drawCalendar,
    connect: () => Promise.reject(new Error('the background sync never opens the device chooser')),
    async reconnect(onLink, signal) {
      if (!deviceId) return undefined;
      const transport = new CapacitorBleTransport({ client: bridgeBleClient(native, deviceId), device: { deviceId } });
      const session = await connectSession(transport, { attempts: 1, retryDelayMs: 3_000, attemptTimeoutMs: 35_000, connectWindowMs: 60_000, onLink, signal });
      return deviceSession(transport, session);
    },
  });
  const result = await backgroundSync(model, () => readCalendar(nativeCalendarHost(native), loadFeeds(), localZone, Date.now()));
  await model.disconnect().catch(() => undefined);
  native.finish(result);
}

const host = (window as { PaperhueSync?: SyncHost }).PaperhueSync;
if (host) {
  const native = new Native(host, window as PageHooks);
  run(native).catch((error: unknown) => native.finish({ outcome: 'error', message: error instanceof Error ? `${error.name}: ${error.message}` : String(error) }));
}
