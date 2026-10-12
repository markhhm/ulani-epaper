/**
 * The diagnostics log: what the page did, plus everything the transport and
 * the session log (commands, replies, retries, upload summaries). Kept in
 * memory only; the page copies it as text for the owner to send back.
 */

import type { LogEntry, Logger, LogLevel } from '../ble/transport';
import { formatClock } from './format';

/** Lines kept before the oldest are dropped. */
export const DEFAULT_LOG_LIMIT = 5_000;

/** Source of the lines the page itself writes. */
export const PAGE_SOURCE = 'page';

/** `14:03:22.045 INFO  session: page 1: stored …` */
export function formatLogLine(entry: LogEntry): string {
  return `${formatClock(entry.time)} ${entry.level.toUpperCase().padEnd(5)} ${entry.source}: ${entry.message}`;
}

export class LogBook {
  /** Pass this as the `log` of a transport or a session. */
  readonly logger: Logger = (entry) => this.push(entry);

  private readonly lines: LogEntry[] = [];
  private droppedCount = 0;
  private readonly entryListeners = new Set<(entry: LogEntry) => void>();
  private readonly clearListeners = new Set<() => void>();
  private readonly limit: number;
  private readonly clock: () => number;

  /** `clock` stamps the page's own lines (default Date.now). */
  constructor(limit: number = DEFAULT_LOG_LIMIT, clock: () => number = () => Date.now()) {
    this.limit = limit;
    this.clock = clock;
  }

  /** A line from the page itself. */
  add(level: LogLevel, message: string): void {
    this.push({ time: this.clock(), level, source: PAGE_SOURCE, message });
  }

  push(entry: LogEntry): void {
    this.lines.push(entry);
    if (this.lines.length > this.limit) {
      this.lines.shift();
      this.droppedCount++;
    }
    for (const listener of [...this.entryListeners]) {
      try {
        listener(entry);
      } catch {
        // A broken view must not break logging.
      }
    }
  }

  entries(): readonly LogEntry[] {
    return this.lines;
  }

  /** Lines dropped because the log was full. */
  get dropped(): number {
    return this.droppedCount;
  }

  clear(): void {
    this.lines.length = 0;
    this.droppedCount = 0;
    for (const listener of [...this.clearListeners]) listener();
  }

  /** Every line, formatted, oldest first. */
  toText(): string {
    const lines = this.lines.map(formatLogLine);
    if (this.droppedCount > 0) lines.unshift(`(${this.droppedCount} earlier lines dropped)`);
    return lines.join('\n');
  }

  onEntry(listener: (entry: LogEntry) => void): () => void {
    this.entryListeners.add(listener);
    return () => {
      this.entryListeners.delete(listener);
    };
  }

  onClear(listener: () => void): () => void {
    this.clearListeners.add(listener);
    return () => {
      this.clearListeners.delete(listener);
    };
  }
}
