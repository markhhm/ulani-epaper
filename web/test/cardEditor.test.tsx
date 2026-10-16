import { render } from 'preact';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AppModel } from '../src/app/model';
import { CardEditor } from '../src/app/ui/CardEditor';
import { parseCard } from '../src/core/cards';
import { MemoryStore } from '../src/core/library';
import { FRAME_BYTES } from '../src/core/protocol';
import { setLocale } from '../src/i18n';
import { FakeNode, installDocument } from './fakeDom';

afterEach(() => {
  setLocale('zh-TW');
});

// The preview is never painted here (a canvas draws nothing in these tests). The stubs stay for this
// file: the editor's effects can still run, and clean up, after a test has ended.
vi.stubGlobal('requestAnimationFrame', () => 0);
vi.stubGlobal('cancelAnimationFrame', () => undefined);

function appModel(store = new MemoryStore()) {
  return new AppModel({
    store,
    drawCard: async () => new Uint8Array(FRAME_BYTES),
    connect: () => Promise.reject(new Error('no device in this test')),
    drawCalendar: async () => new Uint8Array(800 * 480).fill(1),
    drawPhoto: async () => new Uint8Array(800 * 480).fill(2),
  });
}

describe('the colour picker of a photo card', () => {
  it('offers 自然, 明亮 and 經典 and says in one line under it what the chosen one does; leaving 經典 sets 標準', async () => {
    const store = new MemoryStore();
    const model = appModel(store);
    await model.load();
    const card = parseCard({ version: 1, id: 'a1b2c3d4', background: { image: 'a1b2c3d4.jpg', crop: null }, texts: [] });
    const restore = installDocument();
    const root = new FakeNode(1, 'div');
    const show = () => render(<CardEditor model={model} state={model.state} card={card} onClose={() => undefined} />, root as unknown as Element);
    const picker = () => root.all().find((node) => node.localName === 'select' && node.getAttribute('id') === 'card-colours')!;
    const line = () => picker().nextSibling!.textContent;
    const pick = async (value: string) => {
      const select = picker();
      select.listeners.change!.call(select, { type: 'change', currentTarget: { value } });
      await new Promise((resolve) => setTimeout(resolve, 0));
      show();
    };
    try {
      show();
      expect(picker().childNodes.map((option) => [option.getAttribute('value'), option.textContent])).toEqual([
        ['natural', '自然'],
        ['bright', '明亮'],
        ['classic', '經典'],
      ]);
      expect(picker().getAttribute('value')).toBe('natural');
      expect(line()).toBe('顏色最鮮明：藍天等鮮豔的淺色會稍暗，以保留顏色。');

      await pick('classic');
      await model.setGrain(0.5);
      show();
      expect(line()).toBe('舊版的做法：整體較淡，適合本來就是七種純色的圖。');

      await pick('bright');
      expect(picker().getAttribute('value')).toBe('bright');
      expect(line()).toBe('保留原本的明暗：藍天等鮮豔的淺色會偏白。');
      expect(await store.getSettings()).toMatchObject({ colours: 'bright', grain: 1 });

      await model.setGrain(0.8);
      await pick('natural');
      expect(await store.getSettings()).toMatchObject({ colours: 'natural', grain: 0.8 });

      setLocale('en');
      show();
      expect(line()).toBe('Most colour: light, vivid colours such as a blue sky come out a little darker to keep their colour.');
      await pick('bright');
      expect(line()).toBe('Keeps the photo’s brightness: light, vivid colours such as a blue sky lean white.');
    } finally {
      render(null, root as unknown as Element);
      restore();
    }
  });
});
