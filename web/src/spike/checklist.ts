/**
 * The PASS / FAIL checklist of the diagnostics page: one entry per thing the
 * page tries, in the order the steps try them. Names and notes come in every
 * language, so the list follows the language button.
 */

import { getLocale, type Locale, type Localized, same, t } from '../i18n';

export const CHECK_IDS = [
  'webBluetooth',
  'availability',
  'secureContext',
  'writeMethods',
  'calendarFeed',
  'connect',
  'deviceInfo',
  'battery',
  'page',
  'switch',
  'upload',
  'disconnect',
] as const;

export type CheckId = (typeof CHECK_IDS)[number];

/**
 * `warn`: works, but not the way we hoped (or could not be told).
 * `info`: cannot be told yet; a later step decides.
 */
export type CheckStatus = 'pending' | 'running' | 'pass' | 'fail' | 'warn' | 'info';

/** The check's name, e.g. `讀取電量` / `Battery`. */
export function checkName(id: CheckId, locale?: Locale): string {
  return t(`check.${id}`, undefined, locale);
}

/** The status badge, e.g. `PASS` or `未測` / `NOT RUN`. */
export function statusLabel(status: CheckStatus, locale?: Locale): string {
  return t(`badge.${status}`, undefined, locale);
}

export interface CheckState {
  readonly id: CheckId;
  readonly status: CheckStatus;
  /** Short explanation of the status, e.g. the value read or what went wrong. */
  readonly note: Localized;
}

const EMPTY = same('');

export class Checklist {
  private readonly states = new Map<CheckId, CheckState>();
  private readonly listeners = new Set<() => void>();

  constructor() {
    this.reset();
  }

  /** Every check back to `pending`. */
  reset(): void {
    for (const id of CHECK_IDS) this.states.set(id, { id, status: 'pending', note: EMPTY });
    this.changed();
  }

  get(id: CheckId): CheckState {
    return this.states.get(id) as CheckState;
  }

  /** A plain string `note` reads the same in every language. */
  set(id: CheckId, status: CheckStatus, note: Localized | string = EMPTY): void {
    const text = typeof note === 'string' ? same(note) : note;
    const current = this.get(id);
    if (current.status === status && current.note['zh-TW'] === text['zh-TW'] && current.note.en === text.en) return;
    this.states.set(id, { id, status, note: text });
    this.changed();
  }

  /** All checks in CHECK_IDS order. */
  entries(): CheckState[] {
    return CHECK_IDS.map((id) => this.get(id));
  }

  /** How many checks have each status. */
  counts(): Record<CheckStatus, number> {
    const counts: Record<CheckStatus, number> = { pending: 0, running: 0, pass: 0, fail: 0, warn: 0, info: 0 };
    for (const state of this.states.values()) counts[state.status]++;
    return counts;
  }

  /** The counts in one line, e.g. `PASS 3 · FAIL 0 · WARN 1 · INFO 1 · not run 7`. */
  summary(locale: Locale = getLocale()): string {
    return t('checklist.summary', this.counts(), locale);
  }

  /** One line per check, e.g. `[PASS] 讀取電量: 4 / 5` or `[PASS] Battery: 4 / 5`. */
  toText(locale: Locale = getLocale()): string {
    return this.entries()
      .map((state) => {
        const note = state.note[locale];
        return `[${statusLabel(state.status, locale)}] ${checkName(state.id, locale)}${note ? `: ${note}` : ''}`;
      })
      .join('\n');
  }

  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private changed(): void {
    for (const listener of [...this.listeners]) listener();
  }
}
