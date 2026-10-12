/**
 * The page plan: which kind of page each of the device's four pages shows (the same kinds as the
 * other apps, shared/LANGUAGE.md), kept by the app.
 */

import { USER_SLOTS } from './protocol';

export const PAGE_KINDS = ['photo', 'month', 'agenda', 'todo', 'day', 'monthgrid', 'board', 'message', 'card'] as const;
export type PageKind = (typeof PAGE_KINDS)[number];

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

/** The page to offer as a photo page when there is none: page 4, or the first page that is not a card page. */
export function suggestedPhotoSlot(pages: PagePlan): number {
  return pages[4] !== 'card' ? 4 : (USER_SLOTS.find((slot) => pages[slot] !== 'card') ?? 4);
}
