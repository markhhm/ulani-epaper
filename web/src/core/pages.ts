/**
 * The page plan: which kind of page each of the device's four pages shows (kinds named as in the
 * other apps, shared/LANGUAGE.md), kept by the app.
 */

import { USER_SLOTS } from './protocol';

/**
 * The kinds the phone offers. The notes kinds of the other apps (board, message) are not among them:
 * a page saved as one loads as a photo page without a photo (settings.ts), so nothing is sent to it.
 */
export const PAGE_KINDS = ['photo', 'month', 'agenda', 'todo', 'day', 'monthgrid', 'card'] as const;
export type PageKind = (typeof PAGE_KINDS)[number];

/** The kinds drawn from calendar data (shared/LAYOUTS.md). */
export const CALENDAR_KINDS = ['month', 'agenda', 'todo', 'day', 'monthgrid'] as const satisfies readonly PageKind[];
export type CalendarKind = (typeof CALENDAR_KINDS)[number];

/** Page (1-4) -> kind. */
export type PagePlan = Readonly<Record<number, PageKind>>;

export const DEFAULT_PAGES: PagePlan = Object.freeze({ 1: 'month', 2: 'agenda', 3: 'todo', 4: 'photo' });

/** The card pages, lowest number first. */
export function cardPageSlots(pages: PagePlan): number[] {
  return USER_SLOTS.filter((slot) => pages[slot] === 'card');
}

/** The page to offer as a card page when there is none: the lowest-numbered photo page, else page 4. */
export function suggestedCardSlot(pages: PagePlan): number {
  return USER_SLOTS.find((slot) => pages[slot] === 'photo') ?? 4;
}
