import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  keepAwakeMethod,
  keepScreenOn,
  platformEnv,
  type ScreenAwakePlugin,
  type ScreenDimApi,
  type VisibilitySource,
  type WakeLockApi,
  type WakeLockHandle,
} from '../src/keepAwake';

class FakeNative implements ScreenAwakePlugin {
  readonly calls: string[] = [];
  failure: Error | undefined;

  async keepOn(): Promise<void> {
    this.calls.push('keepOn');
    if (this.failure) throw this.failure;
  }

  async allowOff(): Promise<void> {
    this.calls.push('allowOff');
  }
}

class FakeWakeLock implements WakeLockApi {
  readonly requested: string[] = [];
  readonly handles: { released: boolean }[] = [];
  failure: Error | undefined;
  /** Resolve requests only when settle() is called. */
  deferred = false;
  private waiting: (() => void)[] = [];

  request(type: 'screen'): Promise<WakeLockHandle> {
    this.requested.push(type);
    if (this.failure) return Promise.reject(this.failure);
    const state = { released: false };
    this.handles.push(state);
    const handle: WakeLockHandle = {
      release: async () => {
        state.released = true;
      },
    };
    if (!this.deferred) return Promise.resolve(handle);
    return new Promise((resolve) => this.waiting.push(() => resolve(handle)));
  }

  settle(): void {
    for (const resolve of this.waiting.splice(0)) resolve();
  }
}

class FakePage implements VisibilitySource {
  visibilityState: DocumentVisibilityState = 'visible';
  private readonly listeners = new Set<() => void>();

  addEventListener(_type: 'visibilitychange', listener: () => void): void {
    this.listeners.add(listener);
  }

  removeEventListener(_type: 'visibilitychange', listener: () => void): void {
    this.listeners.delete(listener);
  }

  get listening(): number {
    return this.listeners.size;
  }

  show(state: DocumentVisibilityState): void {
    this.visibilityState = state;
    for (const listener of [...this.listeners]) listener();
  }
}

describe('keepAwakeMethod', () => {
  it('prefers the native plugin, then the Wake Lock API', () => {
    expect(keepAwakeMethod({ native: new FakeNative(), wakeLock: new FakeWakeLock() })).toBe('native');
    expect(keepAwakeMethod({ wakeLock: new FakeWakeLock() })).toBe('wakeLock');
    expect(keepAwakeMethod({})).toBe('none');
  });

  it('finds nothing to use outside a browser or the app', () => {
    expect(keepAwakeMethod(platformEnv())).toBe('none');
  });
});

describe('keepScreenOn', () => {
  it('sets and clears the native flag once', async () => {
    const native = new FakeNative();
    const hold = keepScreenOn({ native });
    expect(hold.method).toBe('native');
    expect(await hold.failed).toBeUndefined();
    hold.release();
    hold.release();
    await Promise.resolve();
    await Promise.resolve();
    expect(native.calls).toEqual(['keepOn', 'allowOff']);
  });

  it('reports a native failure without rejecting', async () => {
    const native = new FakeNative();
    native.failure = new Error('no activity');
    expect(await keepScreenOn({ native }).failed).toBe('Error: no activity');
  });

  it('requests a screen lock at once and releases it', async () => {
    const wakeLock = new FakeWakeLock();
    const page = new FakePage();
    const hold = keepScreenOn({ wakeLock, document: page });
    expect(wakeLock.requested).toEqual(['screen']); // synchronously, inside the click
    expect(await hold.failed).toBeUndefined();
    hold.release();
    expect(wakeLock.handles.map((h) => h.released)).toEqual([true]);
    expect(page.listening).toBe(0);
  });

  it('requests the lock again when the page becomes visible, until released', async () => {
    const wakeLock = new FakeWakeLock();
    const page = new FakePage();
    const hold = keepScreenOn({ wakeLock, document: page });
    await hold.failed;
    page.show('hidden');
    expect(wakeLock.requested).toHaveLength(1);
    page.show('visible');
    expect(wakeLock.requested).toHaveLength(2);
    await Promise.resolve();
    hold.release();
    await Promise.resolve();
    expect(wakeLock.handles.every((h) => h.released)).toBe(true);
    page.show('visible');
    expect(wakeLock.requested).toHaveLength(2);
  });

  it('releases a lock that arrives after release()', async () => {
    const wakeLock = new FakeWakeLock();
    wakeLock.deferred = true;
    const hold = keepScreenOn({ wakeLock });
    hold.release();
    wakeLock.settle();
    expect(await hold.failed).toBeUndefined();
    expect(wakeLock.handles.map((h) => h.released)).toEqual([true]);
  });

  it('reports a refused lock without rejecting', async () => {
    const wakeLock = new FakeWakeLock();
    wakeLock.failure = new DOMException('Wake Lock permission request denied', 'NotAllowedError');
    expect(await keepScreenOn({ wakeLock }).failed).toBe('NotAllowedError: Wake Lock permission request denied');
  });

  it('says why when nothing can keep the screen on', async () => {
    const hold = keepScreenOn({});
    expect(hold.method).toBe('none');
    expect(await hold.failed).toMatch(/cannot keep the screen on/);
    hold.release();
  });
});

/** Bluefy's navigator.bluetooth.setScreenDimEnabled. */
class FakeScreenDim implements ScreenDimApi {
  readonly calls: boolean[] = [];
  setScreenDimEnabled(enabled: boolean): void {
    this.calls.push(enabled);
  }
}

describe('Bluefy', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('is found on navigator.bluetooth', () => {
    const screenDim = new FakeScreenDim();
    vi.stubGlobal('navigator', { bluetooth: screenDim });
    expect(platformEnv().screenDim).toBe(screenDim);
    vi.stubGlobal('navigator', { bluetooth: {} });
    expect(platformEnv().screenDim).toBeUndefined();
  });

  it('stops the screen dimming while held, next to the screen lock, and lets it dim again at release', async () => {
    const screenDim = new FakeScreenDim();
    const wakeLock = new FakeWakeLock();
    const hold = keepScreenOn({ wakeLock, screenDim, document: new FakePage() });
    expect(screenDim.calls).toEqual([false]);
    expect(await hold.failed).toBeUndefined();
    hold.release();
    hold.release();
    expect(screenDim.calls).toEqual([false, true]);
    expect(wakeLock.handles.map((h) => h.released)).toEqual([true]);
  });

  it('is enough on its own, and a refused screen lock does not matter then', async () => {
    const screenDim = new FakeScreenDim();
    expect(keepAwakeMethod({ screenDim })).toBe('screenDim');
    const hold = keepScreenOn({ screenDim });
    expect(await hold.failed).toBeUndefined();
    hold.release();
    expect(screenDim.calls).toEqual([false, true]);

    const refused = new FakeWakeLock();
    refused.failure = new DOMException('denied', 'NotAllowedError');
    expect(await keepScreenOn({ wakeLock: refused, screenDim: new FakeScreenDim() }).failed).toBeUndefined();
  });
});
