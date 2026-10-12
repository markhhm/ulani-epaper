/**
 * What the diagnostics page says about the link and the panel refresh, in
 * the page's language: the line at the top (with the attempt number or the
 * countdown to the next attempt) and the note after the page on screen was
 * switched or replaced. Pure, so the countdowns can be tested without a page.
 */

import { type Locale, t } from '../i18n';
import type { LinkActivity } from './diagnostics';

export type LinkTone = 'pass' | 'warn' | 'neutral';

export interface LinkState {
  /** A session exists (connect() succeeded and no disconnect since). */
  readonly session: boolean;
  /** The Bluetooth link is up. */
  readonly connected: boolean;
  /** Advertised name of the device. */
  readonly name?: string | undefined;
  /** What (re)connecting is doing right now. */
  readonly activity?: LinkActivity | undefined;
}

/** Whole seconds from `now` until `until`, rounded up; 0 once it passed. */
export function secondsLeft(until: number, now: number): number {
  return Math.max(0, Math.ceil((until - now) / 1000));
}

/** The link line: connecting attempts and the wait for a refresh first, then up or down. */
export function linkStatus(state: LinkState, now: number, locale?: Locale): { text: string; tone: LinkTone } {
  const activity = state.activity;
  if (activity?.type === 'waiting') {
    return { text: t('link.waiting', { seconds: secondsLeft(activity.until, now) }, locale), tone: 'warn' };
  }
  if (activity?.type === 'attempt') {
    return { text: t('link.reconnecting', { attempt: activity.attempt }, locale), tone: 'warn' };
  }
  if (!state.session) return { text: t('link.notConnected', undefined, locale), tone: 'neutral' };
  if (state.connected) {
    const text = state.name ? t('link.connectedTo', { name: state.name }, locale) : t('link.connected', undefined, locale);
    return { text, tone: 'pass' };
  }
  return { text: t('link.lost', undefined, locale), tone: 'warn' };
}

/**
 * The note after the page on screen was switched or replaced (`endsAt`: when
 * the refresh should be over, which is also when the page reconnects if the
 * link dropped): the device is redrawing, with the seconds left, then that
 * it should be done. Undefined when no refresh is known.
 */
export function refreshNote(endsAt: number | undefined, now: number, locale?: Locale): string | undefined {
  if (endsAt === undefined) return undefined;
  const left = secondsLeft(endsAt, now);
  return left > 0 ? t('refresh.redrawing', { seconds: left }, locale) : t('refresh.done', undefined, locale);
}

/**
 * What the connect step's error box does about the error of the page's own
 * reconnect after a refresh (`current`, undefined once a connection worked),
 * given the one it showed last: show a new one, clear one that is over, or
 * leave the box alone.
 */
export function reconnectErrorChange(shown: unknown, current: unknown): 'show' | 'clear' | 'keep' {
  if (current !== undefined) return current === shown ? 'keep' : 'show';
  return shown === undefined ? 'keep' : 'clear';
}
