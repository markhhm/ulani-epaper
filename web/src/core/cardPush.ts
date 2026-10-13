/**
 * Putting cards on the device, with the rules of the Python reference (sync.py): a pushed card goes
 * to the page it is already on, else the card page on screen, else the lowest card page; a card that
 * is already on a page is only switched to (the device skips an image it holds); cards can be
 * preloaded onto the card pages. The app keeps one fingerprint per page it last filled (`lastSent`)
 * to know which card sits where; the device itself decides whether an upload is needed.
 */

import { crc32 } from './protocol';
import { cardPageSlots, type PagePlan, suggestedCardSlot } from './pages';
import type { PushOptions, UploadResult, WaitOptions } from '../session/session';

/** The part of the device session that pushing cards uses (CalendarSession implements it). */
export interface CardDevice {
  /** The page on screen; with `wait`, asked again while the device is busy or redrawing, as a push does. */
  currentSlot(wait?: WaitOptions): Promise<{ readonly slot: number }>;
  pushPages(frames: ReadonlyMap<number, Uint8Array>, options?: PushOptions): Promise<Map<number, UploadResult>>;
  show(slot: number): Promise<void>;
}

/** What the app knows: the page plan and the fingerprint of the frame last sent to each page. */
export interface PushState {
  readonly pages: PagePlan;
  readonly lastSent: Readonly<Record<number, string>>;
}

export interface PushDone {
  /** The page the card went to. */
  readonly slot: number;
  readonly results: Map<number, UploadResult>;
  /** The panel now redraws (about 40 s, during which the device answers nothing). */
  readonly refreshing: boolean;
  /** The new `lastSent`, to save. */
  readonly lastSent: Record<number, string>;
}

/** No page is a card page. The app can offer, in one tap, to make `suggestedSlot` one. */
export class NoCardPage extends Error {
  override name = 'NoCardPage';
  readonly suggestedSlot: number;
  constructor(suggestedSlot: number) {
    super('no page is a card page');
    this.suggestedSlot = suggestedSlot;
  }
}

/** A short fingerprint of a frame (its CRC-32), what `lastSent` keeps. */
export function frameHash(frame: Uint8Array): string {
  return crc32(frame).toString(16).padStart(8, '0');
}

/**
 * The card page a pushed card goes to: the page it is already on (the one on screen if it is on
 * several), else the card page on screen, else the lowest-numbered card page.
 */
export function cardSlot(slots: readonly number[], preloaded: readonly number[], shown: number): number {
  if (preloaded.includes(shown) || (preloaded.length === 0 && slots.includes(shown))) return shown;
  return preloaded[0] ?? (slots[0] as number);
}

/** `lastSent` after the card pages got `frames`; the other pages keep theirs (a page set to another kind for now still holds its card). */
function remember(state: PushState, frames: ReadonlyMap<number, Uint8Array>): Record<number, string> {
  const kept = { ...state.lastSent };
  for (const [slot, frame] of frames) kept[slot] = frameHash(frame);
  return kept;
}

function slotsOrOffer(pages: PagePlan): number[] {
  const slots = cardPageSlots(pages);
  if (slots.length === 0) throw new NoCardPage(suggestedCardSlot(pages));
  return slots;
}

/** Upload `frame` to `slot` and switch to that page unless it is on screen (`shown`): the panel redraws once. */
async function putOnPage(device: CardDevice, slot: number, shown: number, frame: Uint8Array, options: PushOptions) {
  const results = await device.pushPages(new Map([[slot, frame]]), options);
  if (slot !== shown) await device.show(slot);
  return { slot, results, refreshing: slot !== shown || results.get(slot) === 'ok' };
}

/** Show a picture (a drawn frame) on page `slot` of the device: upload it and switch to the page. */
export async function pushToPage(
  device: CardDevice,
  slot: number,
  frame: Uint8Array,
  options: PushOptions = {},
): Promise<Omit<PushDone, 'lastSent'>> {
  return putOnPage(device, slot, (await device.currentSlot()).slot, frame, options);
}

/**
 * Show a card (already drawn as `frame`) on the device: upload it to the page chosen by cardSlot()
 * and switch to that page. Throws NoCardPage, before touching the device, when no page is a card page.
 */
export async function pushCard(
  device: CardDevice,
  state: PushState,
  frame: Uint8Array,
  options: PushOptions = {},
): Promise<PushDone> {
  const slots = slotsOrOffer(state.pages);
  const hash = frameHash(frame);
  const preloaded = slots.filter((slot) => state.lastSent[slot] === hash);
  const shown = (await device.currentSlot()).slot;
  const done = await putOnPage(device, cardSlot(slots, preloaded, shown), shown, frame, options);
  return { ...done, lastSent: remember(state, new Map([[done.slot, frame]])) };
}

/**
 * Put `frames` (cards already drawn, first on the lowest card page and so on) on the card pages in one
 * push, without switching the display. Throws NoCardPage when no page is a card page, and an Error
 * when there are more cards than card pages, both before touching the device.
 */
export async function preloadCards(
  device: CardDevice,
  state: PushState,
  frames: readonly Uint8Array[],
  options: PushOptions = {},
): Promise<Omit<PushDone, 'slot' | 'refreshing'>> {
  const slots = slotsOrOffer(state.pages);
  if (frames.length > slots.length) throw new Error(`${frames.length} cards do not fit on ${slots.length} card pages`);
  const byPage = new Map(frames.map((frame, i) => [slots[i] as number, frame]));
  const results = await device.pushPages(byPage, options);
  return { results, lastSent: remember(state, byPage) };
}
