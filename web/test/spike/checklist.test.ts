import { describe, expect, it, vi } from 'vitest';
import { message } from '../../src/i18n';
import { CHECK_IDS, Checklist, checkName, statusLabel } from '../../src/spike/checklist';

describe('Checklist', () => {
  it('starts with every check pending, in step order', () => {
    const list = new Checklist();
    expect(list.entries().map((check) => check.id)).toEqual([...CHECK_IDS]);
    expect(list.entries().every((check) => check.status === 'pending')).toBe(true);
    expect(list.counts()).toEqual({ pending: CHECK_IDS.length, running: 0, pass: 0, fail: 0, warn: 0, info: 0 });
  });

  it('checks the calendar download after the browser and before connecting', () => {
    expect(CHECK_IDS.indexOf('calendarFeed')).toBe(CHECK_IDS.indexOf('writeMethods') + 1);
    expect(CHECK_IDS.indexOf('calendarFeed')).toBe(CHECK_IDS.indexOf('connect') - 1);
  });

  it('records statuses and notes, and notifies only on change', () => {
    const list = new Checklist();
    const listener = vi.fn();
    list.onChange(listener);
    list.set('battery', 'pass', '4 / 5');
    list.set('battery', 'pass', '4 / 5');
    list.set('upload', 'fail', message('note.uploadUnchanged', { page: 1 }));
    list.set('upload', 'fail', message('note.uploadUnchanged', { page: 1 }));
    expect(listener).toHaveBeenCalledTimes(2);
    expect(list.get('battery')).toMatchObject({ status: 'pass', note: { 'zh-TW': '4 / 5', en: '4 / 5' } });
    expect(list.get('upload').note.en).toBe('page 1 already holds this card; no data sent');
    expect(list.counts()).toMatchObject({ pass: 1, fail: 1 });
  });

  it('names checks and statuses in both languages', () => {
    expect(checkName('battery', 'zh-TW')).toBe('讀取電量');
    expect(checkName('battery', 'en')).toBe('Battery');
    expect(checkName('calendarFeed', 'zh-TW')).toBe('行事曆下載');
    expect(checkName('calendarFeed', 'en')).toBe('Calendar download');
    expect(statusLabel('pending', 'zh-TW')).toBe('未測');
    expect(statusLabel('pending', 'en')).toBe('NOT RUN');
    expect(statusLabel('pass', 'en')).toBe('PASS');
    // Not decided yet, and not a problem: a later step decides.
    expect(statusLabel('info', 'zh-TW')).toBe('資訊');
    expect(statusLabel('info', 'en')).toBe('INFO');
  });

  it('prints one line per check in the chosen language', () => {
    const list = new Checklist();
    list.set('writeMethods', 'info', 'checked after connecting');
    list.set('battery', 'pass', '4 / 5');
    list.set('upload', 'warn');
    list.set('page', 'pass', message('page.n', { page: 3 }));
    const zh = list.toText('zh-TW').split('\n');
    expect(zh).toHaveLength(CHECK_IDS.length);
    expect(zh).toContain('[PASS] 讀取電量: 4 / 5');
    expect(zh).toContain('[PASS] 讀取目前頁面: 第 3 頁');
    expect(zh).toContain('[WARN] 傳送測試圖');
    expect(zh).toContain('[未測] 中斷連線');
    const en = list.toText('en').split('\n');
    expect(en).toContain('[PASS] Battery: 4 / 5');
    expect(en).toContain('[PASS] Page on screen: Page 3');
    expect(en).toContain('[NOT RUN] Disconnect');
    expect(list.counts()).toMatchObject({ info: 1, pass: 2, warn: 1 });
    expect(en.some((line) => line.startsWith('[INFO] '))).toBe(true);
  });

  it('sums up every check, INFO included, in both languages', () => {
    const list = new Checklist();
    list.set('webBluetooth', 'pass');
    list.set('availability', 'warn');
    list.set('writeMethods', 'info');
    list.set('calendarFeed', 'fail');
    expect(list.summary('en')).toBe('PASS 1 · FAIL 1 · WARN 1 · INFO 1 · not run 8');
    expect(list.summary('zh-TW')).toBe('PASS 1 · FAIL 1 · WARN 1 · 資訊 1 · 未測 8');
    const total = list.summary('en').match(/\d+/g)?.map(Number).reduce((a, b) => a + b, 0);
    expect(total).toBe(CHECK_IDS.length);
  });

  it('resets to pending', () => {
    const list = new Checklist();
    list.set('connect', 'pass');
    list.reset();
    expect(list.get('connect').status).toBe('pending');
  });
});
