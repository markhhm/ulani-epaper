import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  detectLocale,
  getLocale,
  htmlLang,
  LOCALE_STORAGE_KEY,
  type LocaleStore,
  LOCALES,
  localize,
  message,
  onLocaleChange,
  otherLocale,
  pickLocale,
  placeholders,
  same,
  savedLocale,
  saveLocale,
  setLocale,
  STRING_KEYS,
  type StringKey,
  t,
  template,
  toggleLocale,
} from '../src/i18n';

const HAN = /[㐀-鿿]/;

/** Keys that are about calendar DATA (an iCal feed), the only place "calendar" / 行事曆 belongs. */
const CALENDAR_DATA = /^(feed\.|calendar\.|check\.calendarFeed$|report\.feed$)/;

/** Page kinds are the one place 月曆 belongs besides calendar data (shared/LANGUAGE.md: Month, Today + month). */
const PAGE_KIND_NAMES = /^kind./;

/** A localStorage stand-in. */
class MemoryStore implements LocaleStore {
  readonly items = new Map<string, string>();
  getItem(key: string): string | null {
    return this.items.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.items.set(key, value);
  }
}

/** Storage the browser refuses (private mode, blocked site data). */
const refusing: LocaleStore = {
  getItem() {
    throw new DOMException('The operation is insecure.', 'SecurityError');
  },
  setItem() {
    throw new DOMException('The quota has been exceeded.', 'QuotaExceededError');
  },
};

afterEach(() => {
  setLocale('zh-TW');
});

describe('string tables', () => {
  it('has every key in both languages, with the same placeholders', () => {
    expect(STRING_KEYS.length).toBeGreaterThan(100);
    for (const key of STRING_KEYS) {
      const zh = template(key, 'zh-TW');
      const en = template(key, 'en');
      expect(typeof zh === 'string' && zh.trim().length > 0, `zh-TW ${key}`).toBe(true);
      expect(typeof en === 'string' && en.trim().length > 0, `en ${key}`).toBe(true);
      expect(placeholders(zh), key).toEqual(placeholders(en));
    }
  });

  it('writes English without Chinese, except the button that names Chinese', () => {
    for (const key of STRING_KEYS) {
      if (key === 'language.other') continue;
      expect(template(key, 'en'), key).not.toMatch(HAN);
    }
    expect(t('language.other', undefined, 'en')).toBe('中文');
    expect(t('language.other', undefined, 'zh-TW')).toBe('English');
  });

  it('translates every sentence into Chinese', () => {
    for (const key of STRING_KEYS) {
      const en = template(key, 'en');
      // Words (not just PASS, units or API names) need a translation.
      if (/[a-z]{3,} [a-z]{3,}/i.test(en.replace(/BEGIN:VCALENDAR|ULANI e-paper|Web Bluetooth[ A-Z]*/g, ''))) {
        expect(template(key, 'zh-TW'), key).toMatch(HAN);
      }
    }
  });

  it('calls the hardware 裝置 / device, never 月曆 / calendar', () => {
    for (const key of STRING_KEYS) {
      if (!PAGE_KIND_NAMES.test(key)) expect(template(key, 'zh-TW'), key).not.toContain('月曆');
      if (!CALENDAR_DATA.test(key)) {
        expect(template(key, 'en'), key).not.toMatch(/calendar/i);
        expect(template(key, 'zh-TW'), key).not.toContain('行事曆');
      }
    }
    expect(t('connect.note', undefined, 'zh-TW')).toContain('請選名稱以 ULANI 開頭的裝置');
    expect(t('connect.note', undefined, 'en')).toContain('pick the device whose name starts with ULANI');
    expect(t('chooser.scanning', undefined, 'zh-TW')).toBe('正在搜尋裝置…');
    expect(t('chooser.none', undefined, 'en')).toBe('No device found');
  });

  it('names the app Paperhue (紙彩)', () => {
    expect(t('appName', undefined, 'zh-TW')).toBe('Paperhue 紙彩');
    expect(t('appName', undefined, 'en')).toBe('Paperhue');
    for (const locale of LOCALES) {
      expect(t('title.app', undefined, locale)).toMatch(/^Paperhue/);
      expect(t('title.diagnostics', undefined, locale)).toMatch(/^Paperhue .*ULANI e-paper$/);
    }
  });

  it('names the device brand only on the diagnostics page', () => {
    const naming = STRING_KEYS.filter((key) => LOCALES.some((locale) => /ULANI/i.test(template(key, locale))));
    expect(naming.sort()).toEqual(['connect.note', 'diag.intro', 'title.diagnostics']);
  });

  it('uses the page kind names of shared/LANGUAGE.md', () => {
    const kinds = ['photo', 'month', 'agenda', 'todo', 'day', 'monthgrid', 'board', 'message', 'card'] as const;
    expect(kinds.map((k) => t(`kind.${k}`, undefined, 'zh-TW'))).toEqual(['照片', '本日＋月曆', '本日行程＋一週行程', '待辦清單', '日', '月曆', '留言板', '大字留言', '牌卡']);
    expect(kinds.map((k) => t(`kind.${k}`, undefined, 'en'))).toEqual(['Photo', 'Today + month', 'Today + week', 'To-do', 'Day', 'Month', 'Notes board', 'Big message', 'Card']);
  });

  it('says the 50-megapixel refusal as shared/CROP.md words it', () => {
    expect(t('error.photoTooLarge', undefined, 'zh-TW')).toBe('照片超過 5000 萬像素的上限，請先縮小再選。');
    expect(t('error.photoTooLarge', undefined, 'en')).toBe('This photo is over the 50-megapixel limit. Shrink it, then choose it again.');
  });

  it('names the grain levels as shared/LANGUAGE.md does', () => {
    expect(['standard', 'soft', 'softer', 'smoothest'].map((g) => t(`grain.${g}` as StringKey, undefined, 'zh-TW'))).toEqual(['標準', '柔和', '更柔和', '最平滑']);
    expect(t('grain.label', undefined, 'zh-TW')).toBe('顆粒感');
    expect(t('grain.label', undefined, 'en')).toBe('Grain');
  });

  it('fills placeholders and leaves unknown ones', () => {
    expect(t('page.n', { page: 3 }, 'zh-TW')).toBe('第 3 頁');
    expect(t('page.n', { page: 3 }, 'en')).toBe('Page 3');
    expect(t('page.n', undefined, 'en')).toBe('Page {page}');
  });

  it('keeps a text in every language', () => {
    expect(message('page.n', { page: 2 })).toEqual({ 'zh-TW': '第 2 頁', en: 'Page 2' });
    expect(localize((locale) => `${locale}!`)).toEqual({ 'zh-TW': 'zh-TW!', en: 'en!' });
    expect(same('4 / 5')).toEqual({ 'zh-TW': '4 / 5', en: '4 / 5' });
  });
});

describe('choosing the language', () => {
  it('defaults from the browser preferences: zh-* is Chinese, anything else English', () => {
    expect(pickLocale(['zh-TW'])).toBe('zh-TW');
    expect(pickLocale(['zh'])).toBe('zh-TW');
    expect(pickLocale(['zh-Hant-HK', 'en'])).toBe('zh-TW');
    expect(pickLocale(['zh-CN'])).toBe('zh-TW');
    expect(pickLocale(['en-US', 'zh-TW'])).toBe('en');
    expect(pickLocale(['ja-JP', 'zh-TW'])).toBe('zh-TW');
    expect(pickLocale(['ja-JP', 'fr'])).toBe('en');
    expect(pickLocale([])).toBe('en');
  });

  it('uses the browser preferences when nothing was saved', () => {
    expect(detectLocale({ languages: ['zh-TW', 'en'], store: new MemoryStore() })).toBe('zh-TW');
    expect(getLocale()).toBe('zh-TW');
    expect(detectLocale({ languages: ['en-GB'], store: undefined })).toBe('en');
    expect(getLocale()).toBe('en');
    expect(detectLocale({ languages: ['de-DE'], store: refusing })).toBe('en');
  });

  it('looks strings up in the current locale', () => {
    setLocale('en');
    expect(t('connect.button')).toBe('Connect');
    setLocale('zh-TW');
    expect(t('connect.button')).toBe('連線');
    expect(htmlLang('zh-TW')).toBe('zh-Hant-TW');
    expect(htmlLang('en')).toBe('en');
    expect(otherLocale('zh-TW')).toBe('en');
    expect(otherLocale('en')).toBe('zh-TW');
  });

  it('switches every text at once when the button is pressed', () => {
    const store = new MemoryStore();
    detectLocale({ languages: ['zh-TW'], store });
    const keys: StringKey[] = ['diag.heading', 'connect.button', 'feed.title', 'language.other'];
    let shown = keys.map((key) => t(key));
    const listener = vi.fn(() => {
      shown = keys.map((key) => t(key));
    });
    const stop = onLocaleChange(listener);
    expect(shown).toEqual(['Paperhue 紙彩 診斷', '連線', '行事曆下載測試', 'English']);

    expect(toggleLocale(store)).toBe('en');
    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener).toHaveBeenLastCalledWith('en');
    expect(shown).toEqual(['Paperhue diagnostics', 'Connect', 'Calendar download test', '中文']);

    expect(toggleLocale(store)).toBe('zh-TW');
    expect(shown).toEqual(['Paperhue 紙彩 診斷', '連線', '行事曆下載測試', 'English']);
    stop();
    toggleLocale(store);
    expect(listener).toHaveBeenCalledTimes(2);
  });

  it('remembers the choice over the browser preferences', () => {
    const store = new MemoryStore();
    detectLocale({ languages: ['zh-TW'], store });
    toggleLocale(store);
    expect(store.items.get(LOCALE_STORAGE_KEY)).toBe('en');
    expect(savedLocale(store)).toBe('en');
    // Next visit, same browser: the saved choice wins.
    setLocale('zh-TW');
    expect(detectLocale({ languages: ['zh-TW'], store })).toBe('en');

    toggleLocale(store);
    expect(detectLocale({ languages: ['en-US'], store })).toBe('zh-TW');
  });

  it('still switches when the browser refuses storage, and ignores junk', () => {
    detectLocale({ languages: ['zh-TW'], store: refusing });
    expect(toggleLocale(refusing)).toBe('en');
    expect(getLocale()).toBe('en');
    expect(saveLocale('en', refusing)).toBe(false);
    expect(saveLocale('en', undefined)).toBe(false);
    expect(savedLocale(refusing)).toBeUndefined();
    const junk = new MemoryStore();
    junk.setItem(LOCALE_STORAGE_KEY, 'fr');
    expect(savedLocale(junk)).toBeUndefined();
    expect(detectLocale({ languages: ['zh-TW'], store: junk })).toBe('zh-TW');
  });
});
