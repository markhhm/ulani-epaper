import { describe, expect, it, vi } from 'vitest';
import type { LogEntry } from '../../src/ble/transport';
import { formatLogLine, LogBook, PAGE_SOURCE } from '../../src/spike/logbook';

const AT = new Date(2026, 9, 12, 14, 3, 22, 45).getTime();

describe('formatLogLine', () => {
  it('shows the local time, the level, the source and the message', () => {
    const entry: LogEntry = { time: AT, level: 'info', source: 'session', message: 'page 1: stored' };
    expect(formatLogLine(entry)).toBe('14:03:22.045 INFO  session: page 1: stored');
    expect(formatLogLine({ ...entry, level: 'error' })).toBe('14:03:22.045 ERROR session: page 1: stored');
  });
});

describe('LogBook', () => {
  it('stamps its own lines with the clock and the page source', () => {
    const log = new LogBook(10, () => AT);
    log.add('warn', 'hello');
    expect(log.entries()).toEqual([{ time: AT, level: 'warn', source: PAGE_SOURCE, message: 'hello' }]);
  });

  it('takes transport and session entries through its logger', () => {
    const log = new LogBook();
    log.logger({ time: AT, level: 'debug', source: 'web-bluetooth', message: 'write command: 04 4e 42' });
    expect(log.toText()).toBe('14:03:22.045 DEBUG web-bluetooth: write command: 04 4e 42');
  });

  it('drops the oldest lines beyond its limit and says so', () => {
    const log = new LogBook(2, () => AT);
    log.add('info', 'one');
    log.add('info', 'two');
    log.add('info', 'three');
    expect(log.entries().map((entry) => entry.message)).toEqual(['two', 'three']);
    expect(log.dropped).toBe(1);
    expect(log.toText().split('\n')[0]).toBe('(1 earlier lines dropped)');
  });

  it('tells listeners about new lines and clearing, and survives a broken listener', () => {
    const log = new LogBook(10, () => AT);
    const seen: string[] = [];
    log.onEntry(() => {
      throw new Error('broken view');
    });
    const stop = log.onEntry((entry) => seen.push(entry.message));
    const cleared = vi.fn();
    log.onClear(cleared);
    log.add('info', 'a');
    stop();
    log.add('info', 'b');
    expect(seen).toEqual(['a']);
    log.clear();
    expect(cleared).toHaveBeenCalledOnce();
    expect(log.entries()).toEqual([]);
    expect(log.toText()).toBe('');
  });
});
