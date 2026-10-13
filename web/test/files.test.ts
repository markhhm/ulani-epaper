import { afterEach, describe, expect, it, vi } from 'vitest';
import { saveToPhone } from '../src/app/android';
import { saveFile } from '../src/app/ui/files';

const bytes = (...values: number[]) => Uint8Array.from(values);

/** A browser with (or without) a share sheet, on a phone (a coarse pointer) or not. */
function browser(share?: () => Promise<void>) {
  const link = { href: '', download: '', click: vi.fn(), remove: vi.fn() };
  vi.stubGlobal('matchMedia', () => ({ matches: share !== undefined }));
  vi.stubGlobal('navigator', share ? { canShare: () => true, share } : {});
  vi.stubGlobal('document', { createElement: () => link, body: { append: vi.fn() } });
  return link;
}

describe('handing a file to the user', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('says it was handed over when the share sheet took the file', async () => {
    browser(async () => undefined);
    expect(await saveFile('a.zip', bytes(1, 2, 3), 'application/zip')).toBe(true);
  });

  it('says it was not when the share sheet is cancelled', async () => {
    browser(() => Promise.reject(new DOMException('cancelled', 'AbortError')));
    expect(await saveFile('a.zip', bytes(1, 2, 3))).toBe(false);
  });

  it('downloads the file where there is no share sheet', async () => {
    vi.useFakeTimers();
    const link = browser();
    expect(await saveFile('card.paperhue-card', bytes(1))).toBe(true);
    expect(link.download).toBe('card.paperhue-card');
    expect(link.click).toHaveBeenCalledOnce();
  });

  it('downloads the file when the share sheet is not allowed after all', async () => {
    vi.useFakeTimers();
    const link = browser(() => Promise.reject(new DOMException('no', 'NotAllowedError')));
    expect(await saveFile('a.zip', bytes(1))).toBe(true);
    expect(link.click).toHaveBeenCalledOnce();
  });
});

describe('saving a file in the Android app', () => {
  /** The plugin's side: the staged chunks, and what the user did on the "save as" screen. */
  function fakePlugin(saved: boolean) {
    const staged: { first: boolean; bytes: number[] }[] = [];
    const asked: { name: string; type: string }[] = [];
    return {
      staged,
      asked,
      async stageFile({ data, first }: { data: string; first: boolean }) {
        staged.push({ first, bytes: Array.from(atob(data), (c) => c.charCodeAt(0)) });
      },
      async saveFile(options: { name: string; type: string }) {
        asked.push(options);
        return { saved };
      },
    };
  }

  it('hands the whole file over in chunks, then asks where to save it', async () => {
    const plugin = fakePlugin(true);
    const file = Uint8Array.from({ length: 2_500_000 }, (_, i) => i % 251);
    expect(await saveToPhone('backup.zip', file, 'application/zip', plugin)).toBe(true);
    expect(plugin.staged.map((c) => c.first)).toEqual([true, false, false]);
    expect(plugin.staged.flatMap((c) => c.bytes)).toEqual(Array.from(file));
    expect(plugin.asked).toEqual([{ name: 'backup.zip', type: 'application/zip' }]);
  });

  it('says so when the user backs out of the save screen', async () => {
    expect(await saveToPhone('a.paperhue-card', bytes(1), 'application/octet-stream', fakePlugin(false))).toBe(false);
  });

  it('saves an empty file too', async () => {
    const plugin = fakePlugin(true);
    expect(await saveToPhone('empty', new Uint8Array(0), 'application/octet-stream', plugin)).toBe(true);
    expect(plugin.staged).toEqual([{ first: true, bytes: [] }]);
  });
});
