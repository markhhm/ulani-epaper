/**
 * Keeping the screen on during long Bluetooth work. One page takes 25-50 s to
 * upload, a full push about two minutes. If the phone locks its screen
 * meanwhile, the browser suspends the page, the data stops, and the calendar
 * gives up on the frame or drops the link.
 *
 * - Android app: the app's native ScreenAwake plugin
 *   (android/app/src/main/java/.../ScreenAwakePlugin.java) keeps the window's
 *   screen-on flag set. The Android WebView has no Screen Wake Lock API.
 * - Browsers with the Screen Wake Lock API (navigator.wakeLock): a screen
 *   lock, requested again whenever the page becomes visible, because the
 *   browser releases it when the page is hidden.
 * - Bluefy (iPhone) offers navigator.bluetooth.setScreenDimEnabled(false), which stops the screen
 *   dimming and locking; it is switched on again at release. It is used next to the screen lock
 *   (which Bluefy may refuse when nobody tapped) or alone.
 * - Anywhere else nothing can keep the screen on; the page asks the user to.
 */

import { Capacitor, registerPlugin } from '@capacitor/core';

/** How the screen is kept on: `none` means it cannot be. */
export type KeepAwakeMethod = 'native' | 'wakeLock' | 'screenDim' | 'none';

/** The app's native plugin (registered in MainActivity.java). */
export interface ScreenAwakePlugin {
  keepOn(): Promise<void>;
  allowOff(): Promise<void>;
}

/** The part of a WakeLockSentinel used here. */
export interface WakeLockHandle {
  release(): Promise<void>;
}

/** The part of navigator.wakeLock used here. */
export interface WakeLockApi {
  request(type: 'screen'): Promise<WakeLockHandle>;
}

/** The part of Bluefy's navigator.bluetooth used here. */
export interface ScreenDimApi {
  setScreenDimEnabled(enabled: boolean): unknown;
}

/** The part of `document` used here. */
export interface VisibilitySource {
  readonly visibilityState: DocumentVisibilityState;
  addEventListener(type: 'visibilitychange', listener: () => void): void;
  removeEventListener(type: 'visibilitychange', listener: () => void): void;
}

/** Where keepScreenOn looks; tests pass fakes. */
export interface KeepAwakeEnv {
  /** Present inside the Android app. */
  readonly native?: ScreenAwakePlugin;
  /** navigator.wakeLock, where the browser has it. */
  readonly wakeLock?: WakeLockApi;
  /** navigator.bluetooth, in Bluefy. */
  readonly screenDim?: ScreenDimApi;
  readonly document?: VisibilitySource;
}

let plugin: ScreenAwakePlugin | undefined;

/** What this platform offers. */
export function platformEnv(): KeepAwakeEnv {
  if (Capacitor.isNativePlatform()) {
    if (!Capacitor.isPluginAvailable('ScreenAwake')) return {};
    plugin ??= registerPlugin<ScreenAwakePlugin>('ScreenAwake');
    return { native: plugin };
  }
  const nav = typeof navigator === 'undefined' ? undefined : (navigator as { wakeLock?: WakeLockApi; bluetooth?: Partial<ScreenDimApi> });
  return {
    wakeLock: typeof nav?.wakeLock?.request === 'function' ? nav.wakeLock : undefined,
    screenDim: typeof nav?.bluetooth?.setScreenDimEnabled === 'function' ? (nav.bluetooth as ScreenDimApi) : undefined,
    document: typeof document === 'undefined' ? undefined : document,
  };
}

/** How keepScreenOn would keep the screen on here. */
export function keepAwakeMethod(env: KeepAwakeEnv = platformEnv()): KeepAwakeMethod {
  if (env.native) return 'native';
  if (env.wakeLock) return 'wakeLock';
  if (env.screenDim) return 'screenDim';
  return 'none';
}

/** A request to keep the screen on, until release(). */
export interface ScreenHold {
  readonly method: KeepAwakeMethod;
  /**
   * Resolves once the first request settled: undefined when the screen is
   * kept on, otherwise why not (e.g. the browser refused, the battery saver
   * is on, or the platform cannot). Never rejects.
   */
  readonly failed: Promise<string | undefined>;
  /** Let the screen turn off again. Never rejects; calling it again does nothing. */
  release(): void;
}

/**
 * Keep the screen on until release(). Requests synchronously, so calling it
 * straight from a click counts as a user gesture where a browser wants one.
 */
export function keepScreenOn(env: KeepAwakeEnv = platformEnv()): ScreenHold {
  const method = keepAwakeMethod(env);
  if (env.native) {
    const native = env.native;
    let released = false;
    const failed = native.keepOn().then(
      () => undefined,
      (error: unknown) => describe(error),
    );
    return {
      method,
      failed,
      release() {
        if (released) return;
        released = true;
        void failed.then(() => native.allowOff()).catch(() => undefined);
      },
    };
  }
  const lock: ScreenHold = env.wakeLock
    ? wakeLockHold(env.wakeLock, env.document)
    : { method, failed: Promise.resolve('this platform cannot keep the screen on'), release: () => undefined };
  const dim = env.screenDim;
  if (!dim) return lock;
  // Bluefy: no dimming while held. That is enough even when the screen lock is refused.
  let released = false;
  try {
    void dim.setScreenDimEnabled(false);
  } catch (error) {
    return { ...lock, failed: lock.failed.then((why) => why ?? describe(error)) };
  }
  return {
    method,
    failed: Promise.resolve(undefined),
    release() {
      if (released) return;
      released = true;
      lock.release();
      try {
        void dim.setScreenDimEnabled(true);
      } catch {
        // Nothing left to undo.
      }
    },
  };
}

function wakeLockHold(api: WakeLockApi, page: VisibilitySource | undefined): ScreenHold {
  let released = false;
  let handle: WakeLockHandle | undefined;

  const request = (): Promise<string | undefined> => {
    let pending: Promise<WakeLockHandle>;
    try {
      pending = api.request('screen');
    } catch (error) {
      return Promise.resolve(describe(error));
    }
    return pending.then(
      (lock) => {
        if (released) {
          lock.release().catch(() => undefined);
        } else {
          handle = lock;
        }
        return undefined;
      },
      (error: unknown) => describe(error),
    );
  };

  // The browser drops the lock while the page is hidden: take it again on return.
  const onVisibility = () => {
    if (released || page?.visibilityState !== 'visible') return;
    handle?.release().catch(() => undefined); // already released by the browser, normally
    handle = undefined;
    void request();
  };
  page?.addEventListener('visibilitychange', onVisibility);

  return {
    method: 'wakeLock',
    failed: request(),
    release() {
      if (released) return;
      released = true;
      page?.removeEventListener('visibilitychange', onVisibility);
      handle?.release().catch(() => undefined);
      handle = undefined;
    },
  };
}

function describe(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  return String(error);
}
