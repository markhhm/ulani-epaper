import { describe, expect, it } from 'vitest';
import {
  formatBattery,
  formatClock,
  formatCount,
  formatCrc,
  formatRate,
  formatSeconds,
  formatStamp,
  formatStampWithZone,
  percent,
} from '../../src/spike/format';

describe('dates and times (local time)', () => {
  const date = new Date(2026, 9, 12, 4, 3, 2, 45);

  it('formats stamps with zero padding', () => {
    expect(formatStamp(date)).toBe('2026-10-12 04:03:02');
  });

  it('adds the UTC offset', () => {
    expect(formatStampWithZone(date)).toMatch(/^2026-10-12 04:03:02 UTC[+-]\d\d:\d\d$/);
  });

  it('formats log clocks with milliseconds', () => {
    expect(formatClock(date.getTime())).toBe('04:03:02.045');
  });
});

describe('numbers', () => {
  it('formats seconds with one decimal and never negative', () => {
    expect(formatSeconds(32_149)).toBe('32.1 s');
    expect(formatSeconds(0)).toBe('0.0 s');
    expect(formatSeconds(-5)).toBe('0.0 s');
  });

  it('groups digits in threes', () => {
    expect(formatCount(999)).toBe('999');
    expect(formatCount(192_000)).toBe('192 000');
    expect(formatCount(1_234_567)).toBe('1 234 567');
  });

  it('formats rates as KB/s', () => {
    expect(formatRate(6_123)).toBe('6.1 KB/s');
    expect(formatRate(12_000)).toBe('12.0 KB/s');
  });

  it('computes whole percentages within 0-100', () => {
    expect(percent(0, 0)).toBe(0);
    expect(percent(96_000, 192_000)).toBe(50);
    expect(percent(191_999, 192_000)).toBe(99);
    expect(percent(300, 200)).toBe(100);
  });

  it('formats CRCs as eight hex digits', () => {
    expect(formatCrc(0xdeadbeef)).toBe('deadbeef');
    expect(formatCrc(1)).toBe('00000001');
  });
});

describe('formatBattery', () => {
  it('shows the level out of 5, or charging (English unless asked)', () => {
    expect(formatBattery({ level: 4, charging: false })).toBe('4 / 5');
    expect(formatBattery({ level: 0, charging: false }, 'zh-TW')).toBe('0 / 5');
    expect(formatBattery({ level: null, charging: true })).toBe('charging');
    expect(formatBattery({ level: null, charging: true }, 'zh-TW')).toBe('充電中');
  });
});
