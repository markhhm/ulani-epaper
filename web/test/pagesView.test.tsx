import { render } from 'preact';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AppModel, type DeviceSession } from '../src/app/model';
import { TABS } from '../src/app/ui/App';
import { BackgroundControls } from '../src/app/ui/BackgroundControls';
import { pageList, PagesView } from '../src/app/ui/PagesView';
import { frameHash } from '../src/core/cardPush';
import { parseCard } from '../src/core/cards';
import { MemoryStore } from '../src/core/library';
import { FRAME_BYTES } from '../src/core/protocol';
import { setLocale, t } from '../src/i18n';
import { FakeNode, installDocument } from './fakeDom';

// Node decodes no images: a chosen photo is a 1200 x 900 stand-in, kept as the bytes 7 8 9.
vi.mock('../src/app/photoLoad', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../src/app/photoLoad')>()),
  loadPhoto: async () => ({ bitmap: { close: () => undefined }, width: 1200, height: 900 }),
  encodePhoto: async () => ({ jpeg: Uint8Array.of(7, 8, 9), width: 1200, height: 900 }),
}));

afterEach(() => {
  setLocale('zh-TW');
});

/** Let the model's promises and the view's renders run. */
const settled = () => new Promise((resolve) => setTimeout(resolve, 0));

/** A device with page `shown` on screen that records the pages it is asked to show. */
function device(shown: number, calls: string[]): DeviceSession {
  return {
    name: 'Desk',
    connected: true,
    currentSlot: async () => ({ slot: shown, crc32: 0 }),
    pushPages: async () => new Map(),
    show: async (slot) => {
      calls.push(`show ${slot}`);
    },
    battery: async () => ({ level: 4, charging: false }),
    onDisconnect: () => () => undefined,
    close: async () => undefined,
  };
}

function appModel(store = new MemoryStore(), connect: () => Promise<DeviceSession> = () => Promise.reject(new Error('no device in this test'))) {
  return new AppModel({
    store,
    drawCard: async (card) => new Uint8Array(FRAME_BYTES).fill(card.texts[0]?.text.charCodeAt(0) ?? 0),
    connect,
    drawCalendar: async () => new Uint8Array(800 * 480).fill(1),
    drawPhoto: async () => new Uint8Array(800 * 480).fill(2),
  });
}

const isButton = (label: string) => (node: FakeNode) => node.localName === 'button' && node.textContent === label;
const pagesIn = (root: FakeNode) => root.all().filter((node) => node.getAttribute('class') === 'calendar-page');

describe('the sections of the app', () => {
  it('are My cards, Pages and Backup: photos are chosen on their page in Pages', () => {
    expect(TABS).toEqual(['cards', 'pages', 'backup']);
  });
});

describe('the Pages section', () => {
  it('lists all four pages in page order under 「第 N 頁 · <kind>」, photo, calendar and card pages alike', () => {
    const pages = { 1: 'card', 2: 'agenda', 3: 'photo', 4: 'card' } as const;
    setLocale('zh-TW');
    expect(pageList(pages)).toEqual([
      { slot: 1, kind: 'card', title: '第 1 頁 · 牌卡' },
      { slot: 2, kind: 'agenda', title: '第 2 頁 · 本日行程＋一週行程' },
      { slot: 3, kind: 'photo', title: '第 3 頁 · 照片' },
      { slot: 4, kind: 'card', title: '第 4 頁 · 牌卡' },
    ]);
    setLocale('en');
    expect(pageList({ 1: 'month', 2: 'card', 3: 'monthgrid', 4: 'photo' }).map((page) => page.title)).toEqual([
      'Page 1 · Today + month',
      'Page 2 · Card',
      'Page 3 · Month',
      'Page 4 · Photo',
    ]);
  });

  it('shows every page, a card page with the card this app put there and the way to the cards, and offers no notes pages', async () => {
    const store = new MemoryStore();
    const model = appModel(store);
    await model.load();
    await model.setPageKind(1, 'card');
    await model.setPageKind(3, 'card');
    const card = await model.saveCard(parseCard({ version: 1, id: '00000000', background: { color: 'white' }, texts: [{ text: 'A', box: [0, 0, 1, 0.5] }] }));
    await store.setSettings({ ...model.state.settings, lastSent: { 1: frameHash(await model.frameFor(card)) } }); // page 1 holds it
    await model.load();

    const restore = installDocument();
    const root = new FakeNode(1, 'div');
    let opened = 0;
    try {
      render(<PagesView model={model} state={model.state} onCards={() => opened++} />, root as unknown as Element);
      const pages = pagesIn(root);
      expect(pages.map((page) => page.childNodes[0]?.textContent)).toEqual(['第 1 頁 · 牌卡', '第 2 頁 · 本日行程＋一週行程', '第 3 頁 · 牌卡', '第 4 頁 · 照片']);
      const [first, , third] = pages as [FakeNode, FakeNode, FakeNode, FakeNode];
      expect(first.all().some((node) => node.localName === 'canvas')).toBe(true); // the card on page 1
      expect(third.all().some((node) => node.localName === 'canvas')).toBe(false); // nothing known on page 3
      for (const page of [first, third]) {
        expect(page.textContent).toContain('到「我的牌卡」選一張牌卡送到這一頁。');
        page.all().find(isButton('前往「我的牌卡」'))?.click();
      }
      expect(opened).toBe(2);
      const kinds = root.all().find((node) => node.getAttribute('id') === 'kind-1');
      expect(kinds?.childNodes.map((option) => option.textContent)).toEqual(['照片', '本日＋月曆', '本日行程＋一週行程', '待辦清單', '日', '月曆', '牌卡']);
    } finally {
      render(null, root as unknown as Element);
      restore();
    }
  });

  it('has 「在裝置上顯示」 on every page, which puts that page on screen, and is off while another job runs', async () => {
    expect(t('pages.show', undefined, 'en')).toBe('Show on device');
    const calls: string[] = [];
    const model = appModel(new MemoryStore(), async () => device(1, calls));
    await model.load();
    await model.setPageKind(3, 'card'); // 1 and 2 are calendar pages, 4 a photo page without a photo

    const restore = installDocument();
    const root = new FakeNode(1, 'div');
    try {
      render(<PagesView model={model} state={model.state} onCards={() => undefined} />, root as unknown as Element);
      const buttons = pagesIn(root).map((page) => page.all().find(isButton('在裝置上顯示')));
      expect(buttons).toHaveLength(4);
      expect(buttons.every((button) => button !== undefined && button.getAttribute('disabled') === null)).toBe(true);
      buttons[2]?.click();
      await settled();
      expect(calls).toEqual(['show 3']);
      expect(model.state.notice).toEqual({ kind: 'show', slot: 3, unchanged: false, redraws: true });

      render(<PagesView model={model} state={{ ...model.state, job: { kind: 'push' } }} onCards={() => undefined} />, root as unknown as Element);
      const busy = pagesIn(root).map((page) => page.all().find(isButton('在裝置上顯示')));
      expect(busy.map((button) => button?.getAttribute('disabled'))).toEqual(['true', 'true', 'true', 'true']);
    } finally {
      render(null, root as unknown as Element);
      restore();
    }
  });
});

describe('the colours and the grain', () => {
  it('are two pickers, 顏色 (自然, 經典) right before 顆粒感; 自然 sets the grain to 標準, 經典 keeps it', async () => {
    const store = new MemoryStore();
    const model = appModel(store);
    await model.load();
    const restore = installDocument();
    const root = new FakeNode(1, 'div');
    const show = () => render(<PagesView model={model} state={model.state} onCards={() => undefined} />, root as unknown as Element);
    const groups = () => root.all().filter((node) => node.getAttribute('role') === 'radiogroup');
    const tap = async (label: string) => {
      root.all().find(isButton(label))?.click();
      await settled();
      show();
    };
    const checked = () => groups().map((group) => group.childNodes.filter((b) => b.getAttribute('aria-checked') === 'true').map((b) => b.textContent));
    try {
      show();
      expect(groups().map((group) => group.getAttribute('aria-label'))).toEqual(['顏色', '顆粒感']);
      expect(groups().map((group) => group.childNodes.map((button) => button.textContent))).toEqual([
        ['自然', '經典'],
        ['標準', '柔和', '更柔和', '最平滑'],
      ]);
      expect(checked()).toEqual([['自然'], ['標準']]);

      await tap('經典');
      await tap('最平滑');
      expect(checked()).toEqual([['經典'], ['最平滑']]);
      expect(await store.getSettings()).toMatchObject({ colours: 'classic', grain: 0.5 });

      await tap('自然');
      expect(checked()).toEqual([['自然'], ['標準']]);
      expect(await store.getSettings()).toMatchObject({ colours: 'natural', grain: 1 });

      await tap('柔和'); // the grain stays adjustable with 自然
      await tap('經典');
      expect(checked()).toEqual([['經典'], ['柔和']]);
      expect(await store.getSettings()).toMatchObject({ colours: 'classic', grain: 0.8 });
    } finally {
      render(null, root as unknown as Element);
      restore();
    }
  });
});

describe('a new photo for a photo page', () => {
  /** Choose a photo for photo page 4, which has one and shows it as `fit`. */
  async function choose(fit: 'cover' | 'contain') {
    const store = new MemoryStore();
    const model = appModel(store);
    await model.load();
    await model.setPageBackground(4, [0, 0.1, 1, 0.8], { jpeg: Uint8Array.of(1, 2, 3), width: 1200, height: 900 });
    await model.setPhotoFit(4, fit);
    const restore = installDocument();
    const root = new FakeNode(1, 'div');
    let changes = 0;
    try {
      const controls = () => <BackgroundControls model={model} slot={4} stored={model.state.settings.backgrounds[4]} photoPage onChange={() => changes++} />;
      render(controls(), root as unknown as Element);
      const input = root.all().find((node) => node.localName === 'input') as FakeNode;
      input.listeners.change?.call(input, { type: 'change', currentTarget: { files: [new Blob([Uint8Array.of(9)])], value: 'photo.jpg' } });
      await settled();
      render(controls(), root as unknown as Element);
      await settled();
      return { model, store, changes, cropping: root.all().some((node) => node.getAttribute('role') === 'dialog') };
    } finally {
      render(null, root as unknown as Element);
      restore();
    }
  }

  it('shown whole (white edges) is kept at once, uncropped, without the crop editor', async () => {
    const { model, store, changes, cropping } = await choose('contain');
    expect(cropping).toBe(false);
    expect(changes).toBe(1);
    expect(model.state.settings.backgrounds[4]).toEqual({ image: 'page-4.jpg', crop: null, fit: 'contain' });
    expect(await store.getBackground('page-4.jpg')).toEqual(Uint8Array.of(7, 8, 9));
  });

  it('filling the screen opens the crop editor first, and nothing is kept yet', async () => {
    const { model, store, changes, cropping } = await choose('cover');
    expect(cropping).toBe(true);
    expect(changes).toBe(0);
    expect(model.state.settings.backgrounds[4]).toEqual({ image: 'page-4.jpg', crop: [0, 0.1, 1, 0.8] });
    expect(await store.getBackground('page-4.jpg')).toEqual(Uint8Array.of(1, 2, 3));
  });
});
