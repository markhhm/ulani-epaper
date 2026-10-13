import { render } from 'preact';
import { afterEach, describe, expect, it } from 'vitest';
import { AppModel } from '../src/app/model';
import { TABS } from '../src/app/ui/App';
import { pageList, PagesView } from '../src/app/ui/PagesView';
import { frameHash } from '../src/core/cardPush';
import { parseCard } from '../src/core/cards';
import { MemoryStore } from '../src/core/library';
import { FRAME_BYTES } from '../src/core/protocol';
import { setLocale } from '../src/i18n';
import { FakeNode, installDocument } from './fakeDom';

afterEach(() => {
  setLocale('zh-TW');
});

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
    const model = new AppModel({
      store,
      drawCard: async (card) => new Uint8Array(FRAME_BYTES).fill(card.texts[0]?.text.charCodeAt(0) ?? 0),
      connect: () => Promise.reject(new Error('no device in this test')),
      drawCalendar: async () => new Uint8Array(800 * 480).fill(1),
      drawPhoto: async () => new Uint8Array(800 * 480).fill(2),
    });
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
      const pages = root.all().filter((node) => node.getAttribute('class') === 'calendar-page');
      expect(pages.map((page) => page.childNodes[0]?.textContent)).toEqual(['第 1 頁 · 牌卡', '第 2 頁 · 本日行程＋一週行程', '第 3 頁 · 牌卡', '第 4 頁 · 照片']);
      const [first, , third] = pages as [FakeNode, FakeNode, FakeNode, FakeNode];
      expect(first.all().some((node) => node.localName === 'canvas')).toBe(true); // the card on page 1
      expect(third.all().some((node) => node.localName === 'canvas')).toBe(false); // nothing known on page 3
      for (const page of [first, third]) {
        expect(page.textContent).toContain('到「牌卡」分頁選一張牌卡送到這一頁。');
        page.all().find((node) => node.localName === 'button' && node.textContent === '前往「我的牌卡」')?.click();
      }
      expect(opened).toBe(2);
      const kinds = root.all().find((node) => node.getAttribute('id') === 'kind-1');
      expect(kinds?.childNodes.map((option) => option.textContent)).toEqual(['照片', '本日＋月曆', '本日行程＋一週行程', '待辦清單', '日', '月曆', '牌卡']);
    } finally {
      render(null, root as unknown as Element);
      restore();
    }
  });
});
