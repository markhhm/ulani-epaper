import { describe, expect, it } from 'vitest';
import { linkStatus, reconnectErrorChange, refreshNote, secondsLeft } from '../../src/spike/linkStatus';

const NOW = 1_000_000;

describe('secondsLeft', () => {
  it('rounds up and never goes below zero', () => {
    expect(secondsLeft(NOW + 45_000, NOW)).toBe(45);
    expect(secondsLeft(NOW + 44_001, NOW)).toBe(45);
    expect(secondsLeft(NOW + 1, NOW)).toBe(1);
    expect(secondsLeft(NOW, NOW)).toBe(0);
    expect(secondsLeft(NOW - 5_000, NOW)).toBe(0);
  });
});

describe('linkStatus', () => {
  it('counts down while waiting for the device to finish redrawing', () => {
    const state = { session: true, connected: false, activity: { type: 'waiting', until: NOW + 25_000 } } as const;
    expect(linkStatus(state, NOW, 'zh-TW')).toEqual({ text: '等裝置刷新完畫面：25 秒後連線', tone: 'warn' });
    expect(linkStatus(state, NOW, 'en')).toEqual({
      text: 'Waiting for the device to finish redrawing: connecting in 25 s',
      tone: 'warn',
    });
    expect(linkStatus(state, NOW + 24_500, 'en').text).toContain('in 1 s');
  });

  it('names the attempt while connecting, also before there is a session', () => {
    const state = { session: false, connected: false, activity: { type: 'attempt', attempt: 2 } } as const;
    expect(linkStatus(state, NOW, 'zh-TW')).toEqual({ text: '連線中（第 2 次）…', tone: 'warn' });
    expect(linkStatus(state, NOW, 'en')).toEqual({ text: 'Connecting (attempt 2)…', tone: 'warn' });
  });

  it('says whether the link is up otherwise', () => {
    expect(linkStatus({ session: false, connected: false }, NOW, 'en')).toEqual({ text: 'Not connected', tone: 'neutral' });
    expect(linkStatus({ session: true, connected: true, name: 'ULANI 1A2B3C' }, NOW, 'en')).toEqual({
      text: 'Connected: ULANI 1A2B3C',
      tone: 'pass',
    });
    expect(linkStatus({ session: true, connected: true }, NOW, 'zh-TW')).toEqual({ text: '已連線', tone: 'pass' });
    expect(linkStatus({ session: true, connected: false }, NOW, 'en')).toEqual({
      text: 'Link lost: the next action reconnects',
      tone: 'warn',
    });
  });
});

describe('refreshNote', () => {
  it('counts down the redraw and promises a reconnect only if the link drops, not as an error', () => {
    expect(refreshNote(NOW + 45_000, NOW, 'zh-TW')).toBe('裝置正在刷新畫面（約剩 45 秒）；這段時間如果斷線，會自動重新連線。');
    expect(refreshNote(NOW + 45_000, NOW, 'en')).toBe(
      'The device is redrawing its screen (about 45 s left); if the link drops meanwhile, it reconnects by itself.',
    );
    expect(refreshNote(NOW + 45_000, NOW + 30_000, 'en')).toContain('about 15 s left');
  });

  it('says when the redraw should be over, the same in both languages, and nothing when there was none', () => {
    expect(refreshNote(NOW, NOW, 'en')).toBe('The device should be done redrawing its screen.');
    expect(refreshNote(NOW - 1, NOW, 'zh-TW')).toBe('裝置應該已經刷新完畫面。');
    expect(refreshNote(undefined, NOW, 'en')).toBeUndefined();
  });
});

describe('reconnectErrorChange', () => {
  const first = new Error('first');
  const second = new Error('second');

  it('shows a new error of the page’s own reconnect', () => {
    expect(reconnectErrorChange(undefined, first)).toBe('show');
    expect(reconnectErrorChange(first, second)).toBe('show');
  });

  it('clears the error once the link recovered, and otherwise leaves the box alone', () => {
    expect(reconnectErrorChange(first, undefined)).toBe('clear');
    expect(reconnectErrorChange(first, first)).toBe('keep');
    expect(reconnectErrorChange(undefined, undefined)).toBe('keep');
  });
});
