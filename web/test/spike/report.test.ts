import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FRAME_BYTES } from '../../src/core/protocol';
import { Diagnostics, type UploadReport } from '../../src/spike/diagnostics';
import { buildReport, describeUpload } from '../../src/spike/report';
import { FakeCalendar, settle } from '../session/fakeCalendar';

const BASE: UploadReport = {
  settings: { page: 1, writeMode: 'auto', chunkSize: 180, flushEvery: 10 },
  outcome: 'ok',
  startedAt: 0,
  stamp: '2026-10-12 14:03:22',
  frameBytes: FRAME_BYTES,
  sent: FRAME_BYTES,
  packets: 1067,
  chunkSize: 180,
  applied: { writeMode: true, chunkSize: true },
  totalMs: 31_200,
  setupMs: 400,
  dataMs: 29_800,
  waitMs: 1_000,
  bytesPerSecond: 6_400,
  onScreen: false,
  refreshing: false,
};

describe('describeUpload', () => {
  it('summarises a successful upload', () => {
    expect(describeUpload(BASE)).toBe(
      'page 1, auto, 180 B, flush 10: OK, total 31.2 s, data 29.8 s, 6.4 KB/s, result after 1.0 s, 1067 packets of 180 B',
    );
  });

  it('summarises "unchanged", errors and the panel refresh', () => {
    expect(describeUpload({ ...BASE, outcome: 'unchanged', settings: { ...BASE.settings, resend: true } })).toBe(
      'page 1, auto, 180 B, flush 10, resend: unchanged, 31.2 s',
    );
    const failed = describeUpload({
      ...BASE,
      outcome: 'error',
      error: new Error('page 1: the device rejected the image (02 01)'),
      sent: 1_800,
      settings: { ...BASE.settings, flushEvery: 0 },
    });
    expect(failed).toBe(
      'page 1, auto, 180 B, flush off: ERROR after 31.2 s, 1 800 / 192 000 bytes: Error: page 1: the device rejected the image (02 01)',
    );
    expect(describeUpload({ ...BASE, refreshing: true })).toMatch(/, panel refreshing$/);
  });
});

describe('buildReport', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 9, 12, 14, 3, 22));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  async function fullRun(): Promise<Diagnostics> {
    const calendar = new FakeCalendar({ shown: 3 });
    const diagnostics = new Diagnostics({
      createTransport: () => calendar,
      session: { replyTimeoutMs: 50, resultTimeoutMs: 500, busyRetryDelayMs: 10 },
      now: () => Date.now(),
      fetch: async () => Promise.reject(new TypeError('Failed to fetch')),
    });
    await diagnostics.checkBrowser({
      bluetooth: { requestDevice() {} },
      isSecureContext: true,
      protocol: 'https:',
      characteristicClass: undefined,
      userAgent: 'Test/1.0',
    });
    await settle(diagnostics.connect());
    await settle(diagnostics.readStatus());
    await settle(diagnostics.sendTestCard({ page: 1, writeMode: 'auto', chunkSize: 180, flushEvery: 10 }));
    await diagnostics.downloadCalendar();
    return diagnostics;
  }

  it('holds the checklist, the calendar download, the device, the status, the uploads and the log', async () => {
    const diagnostics = await fullRun();
    const text = buildReport(diagnostics, new Date(), 'https://example.test/spike.html', 'zh-TW');
    expect(text).toMatch(/^Paperhue 紙彩 診斷紀錄\n時間: 2026-10-12 14:03:22 UTC[+-]\d\d:\d\d\n/);
    expect(text).toContain('網頁: https://example.test/spike.html');
    expect(text).toContain('User agent: Test/1.0');
    expect(text).toContain('Browser: bluetooth=yes, availability=missing, secureContext=true');
    expect(text).toContain('[PASS] 連線、通知、解鎖: Fake Calendar 000000');
    expect(text).toContain('[PASS] 讀取目前頁面: 第 3 頁');
    expect(text).toContain('[FAIL] 行事曆下載: BLOCKED: TypeError: Failed to fetch');
    expect(text).toContain(
      '行事曆下載: BLOCKED: TypeError: Failed to fetch (0.0 s)\n' +
        '瀏覽器擋下了下載（CORS 或網路錯誤），所以在這個瀏覽器裡無法同步行事曆頁面。\n',
    );
    expect(text).toContain('裝置: Fake Calendar 000000 via fake, model P7320E-B, firmware v1.0.09');
    expect(text).toContain('狀態: battery 4 / 5, page on screen 3 (crc deadbeef)');
    expect(text).toContain('- page 1, auto, 180 B, flush 10: OK');
    expect(text).toContain('紀錄:\n');
    expect(text).toContain('session: > 04 4e 42');
    expect(text).toContain('page: calendar download: BLOCKED');
    expect(text).not.toContain('月曆');
    expect(text.endsWith('\n')).toBe(true);
  });

  it('speaks English when the page does', async () => {
    const diagnostics = await fullRun();
    const text = buildReport(diagnostics, new Date(), 'https://example.test/spike.html', 'en');
    expect(text).toMatch(/^Paperhue diagnostics log\nTime: 2026-10-12 14:03:22 UTC[+-]\d\d:\d\d\n/);
    expect(text).toContain('[PASS] Connect, notifications, unlock: Fake Calendar 000000');
    expect(text).toContain('[PASS] Page on screen: Page 3');
    expect(text).toContain(
      'Calendar download: BLOCKED: TypeError: Failed to fetch (0.0 s)\n' +
        'The browser blocked the download (CORS or network error), so calendar pages cannot be synced in this browser.\n',
    );
    expect(text).toContain('Device: Fake Calendar 000000 via fake');
    expect(text).toContain('Log:\n');
    expect(text).not.toMatch(/[\u3400-\u9fff]/);
  });

  it('adds the write methods of the device characteristic when the transport told them', async () => {
    class WebLikeCalendar extends FakeCalendar {
      writeMethods() {
        return { writeValueWithoutResponse: true, writeValueWithResponse: false, writeValue: true };
      }
    }
    const diagnostics = new Diagnostics({
      createTransport: () => new WebLikeCalendar(),
      session: { replyTimeoutMs: 50 },
      now: () => Date.now(),
    });
    await settle(diagnostics.connect());
    const text = buildReport(diagnostics, new Date(), '', 'en');
    expect(text).toContain(
      'Device: Fake Calendar 000000 via fake, model P7320E-B, firmware v1.0.09\n' +
        'Image characteristic: writeValueWithoutResponse=yes, writeValueWithResponse=no, writeValue=yes\n',
    );
    const before = buildReport(await fullRun(), new Date(), '', 'en');
    expect(before).not.toContain('Image characteristic:');
  });

  it('reports a calendar download that worked', async () => {
    const ics = ['BEGIN:VCALENDAR', 'BEGIN:VEVENT', 'END:VEVENT', 'END:VCALENDAR', ''].join('\r\n');
    const diagnostics = new Diagnostics({
      createTransport: () => new FakeCalendar(),
      now: () => Date.now(),
      fetch: async () => new Response(ics),
    });
    await diagnostics.downloadCalendar();
    const text = buildReport(diagnostics, new Date(), '', 'en');
    expect(text).toContain(`[PASS] Calendar download: HTTP 200, ${ics.length} bytes, BEGIN:VCALENDAR`);
    expect(text).toContain(
      `Calendar download: PASS, HTTP 200, ${ics.length} bytes, starts with BEGIN:VCALENDAR, 1 events, 0.0 s\n` +
        'This browser can download calendar feeds directly, so calendar pages can be synced here.\n',
    );
  });

  it('works before anything ran', () => {
    const diagnostics = new Diagnostics({ createTransport: () => new FakeCalendar() });
    const text = buildReport(diagnostics, new Date(), '', 'zh-TW');
    expect(text).toContain('[未測] 瀏覽器支援藍牙');
    expect(text).toContain('[未測] 行事曆下載');
    expect(text).toContain('紀錄:\n（空白）\n');
    expect(text).not.toContain('網頁');
    expect(buildReport(diagnostics, new Date(), '', 'en')).toContain('[NOT RUN] Web Bluetooth API');
  });
});
