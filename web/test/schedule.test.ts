import { describe, expect, it } from 'vitest';
import { runText } from '../src/app/ui/AndroidView';
import { scheduleTimes } from '../src/core/schedule';

describe('scheduled sync on Android', () => {
  it('keeps the chosen times as sorted HH:MM without repeats, and has no default', () => {
    expect(scheduleTimes([])).toEqual([]);
    expect(scheduleTimes(['17:30', '08:05', '17:30', '8:00', '24:00', ''])).toEqual(['08:05', '17:30']);
  });

  it('says in both languages what each run did, without any calendar content', () => {
    const at = new Date(2026, 9, 13, 8, 0).getTime();
    const retryAt = new Date(2026, 9, 13, 8, 15).getTime();
    expect(runText({ at, result: { outcome: 'notFound' }, retryAt }, 'en')).toBe('10/13 08:00 · Device not found: trying again at 08:15.');
    expect(runText({ at, result: { outcome: 'notFound' }, gaveUp: true }, 'zh-TW')).toBe('10/13 08:00 · 兩小時內都找不到裝置，這次略過。');
    expect(runText({ at, result: { outcome: 'done', updated: [2], unchanged: [1, 3] } }, 'en')).toBe('10/13 08:00 · Sync finished. Updated: Page 2. Already up to date: Page 1, Page 3.');
    expect(runText({ at, result: { outcome: 'feedError', feed: '工作', reason: 'http', status: 404 } }, 'en')).toMatch(/^10\/13 08:00 · 工作: HTTP 404/);
  });
});
