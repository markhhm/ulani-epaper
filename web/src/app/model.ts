/**
 * What the app knows and does, apart from how it looks: the saved cards and settings, the link to
 * the device, and the jobs (pushing a card, preloading cards, sending a photo). Components read
 * `state` and call the methods; every browser or Bluetooth specific thing comes in through
 * `ModelDeps`, so this runs in Node tests with fakes.
 */

import { type AgendaData } from '../core/agenda';
import { type Card } from '../core/cards';
import { cardSig } from '../core/cardRender';
import type { Crop } from '../core/crop';
import {
  type CardDevice,
  frameHash,
  NoCardPage,
  preloadCards,
  pushCard,
  pushToPage,
} from '../core/cardPush';
import {
  addCard,
  clearPageBackground,
  exportBackup,
  exportCardFile,
  importBackup,
  importCardFile,
  type PreparedPhoto,
  type PreparePhoto,
  removeCard,
  setPageBackground,
  type Store,
  updateCard,
} from '../core/library';
import { type CalendarKind, CALENDAR_KINDS, cardPageSlots, type PageKind, suggestedCardSlot } from '../core/pages';
import { packIndices } from '../core/frame';
import { type Battery, USER_SLOTS } from '../core/protocol';
import type { ColourMode } from '../core/dither';
import { defaultSettings, type Dithering, type Settings, setColours, setPageKind } from '../core/settings';
import type { SyncRequest } from '../core/shortcut';
import { ConnectFailed, type LinkEvent, PushFailed, type PushEvent, SESSION_DEFAULTS, type UploadResult } from '../session/session';

/** The connected device, as the model uses it (CalendarSession plus a name; see app/device.ts). */
export interface DeviceSession extends CardDevice {
  readonly name: string | undefined;
  readonly connected: boolean;
  battery(): Promise<Battery>;
  onDisconnect(listener: (reason: 'requested' | 'lost') => void): () => void;
  close(): Promise<void>;
}

export interface ModelDeps {
  store: Store;
  /** Draw `card`, its photo dithered with `dithering`; `background` holds its stored photo, if it has one. */
  drawCard(card: Card, dithering: Dithering, background: Uint8Array | undefined): Promise<Uint8Array>;
  /** Connect to a device. Called straight from a tap: Web Bluetooth only opens its chooser then. */
  connect(onLink: (event: LinkEvent) => void): Promise<DeviceSession>;
  /**
   * Connect to the device this browser already knows, without a tap or the chooser; resolves
   * undefined when there is none. Gives up (ConnectFailed) after about a minute.
   */
  reconnect?(onLink: (event: LinkEvent) => void, signal: AbortSignal): Promise<DeviceSession | undefined>;
  /**
   * A calendar page of `kind` as palette indices, drawn from `calendar` (the phone's), else the default
   * calendar; on `background` (the stored photo, cut to `crop` and dithered with its `colours` and `grain`) when given.
   */
  drawCalendar?(kind: CalendarKind, calendar?: AgendaData, background?: PageBackgroundPhoto): Promise<Uint8Array>;
  /** A photo page as palette indices: its stored photo, cut to `crop` (or whole, with `fit`) and dithered with `colours` and `grain`. */
  drawPhoto?(photo: PageBackgroundPhoto): Promise<Uint8Array>;
  /** Photo file bytes -> a photo as the app keeps it (the 50 MP refusal and the 4K cap). */
  preparePhoto?: PreparePhoto;
  /** Keep the screen on until released (uploads take a minute or two). */
  keepAwake?(): { release(): void };
  now?(): Date;
}

/** The photo behind a calendar page, or of a photo page, as the drawing needs it, with how to dither it. */
export interface PageBackgroundPhoto extends Dithering {
  /** The stored photo (JPEG). */
  photo: Uint8Array;
  crop: Crop | null;
  /** A photo page that shows the whole photo with white edges (the crop is not used). */
  fit?: 'contain';
}

/** What (re)connecting is doing right now: waiting for a panel redraw to end, or making attempt N. */
export type LinkActivity = Extract<LinkEvent, { type: 'waiting' | 'attempt' }>;

export type JobKind = 'connect' | 'push' | 'preload' | 'photo' | 'calendar' | 'show' | 'sync';

/** How a sync from the iPhone Shortcut ended (pages are numbered 1-4). */
export type SyncOutcome =
  | { outcome: 'done'; updated: number[]; unchanged: number[] }
  | { outcome: 'failed'; updated: number[]; unchanged: number[]; page?: number }
  /** Not found within about a minute. */
  | { outcome: 'notFound' }
  /** This browser has never been connected to a device. */
  | { outcome: 'notPaired' }
  /** No page is a calendar page. */
  | { outcome: 'noPages' }
  /** The Shortcut's data could not be read. */
  | { outcome: 'unreadable' };

export interface ModelState {
  /** Cards and settings are loaded. */
  ready: boolean;
  /** Newest first. */
  cards: Card[];
  settings: Settings;
  link: { connected: boolean; name?: string; battery?: Battery; activity?: LinkActivity | undefined };
  /** What the device is being asked to do right now. */
  job?: { kind: JobKind; progress?: PushEvent };
  /** The last thing that went wrong; shown until dismissed. */
  error?: unknown;
  /** A card was tapped but no page is a card page: offer to make `slot` one. */
  offer?: { slot: number; card: Card };
  /** The panel is redrawing until this time (a Date time). */
  refreshUntil?: number;
  /** The last sync from the iPhone Shortcut, until dismissed. */
  sync?: SyncOutcome;
  /** The calendar pages show the phone's calendar (from the Shortcut) instead of the default one. */
  phoneCalendar?: true;
  /** What the last job did, until the next one starts ('show': `unchanged` when the page was on screen already). */
  notice?:
    | { kind: 'card' | 'photo' | 'calendar' | 'show'; slot: number; unchanged: boolean; redraws: boolean }
    | { kind: 'preload'; count: number };
}

const REFRESH_MS = SESSION_DEFAULTS.refreshWaitMs;

export class AppModel {
  state: ModelState = { ready: false, cards: [], settings: defaultSettings(), link: { connected: false } };

  private readonly deps: ModelDeps;
  private readonly listeners = new Set<() => void>();
  private session: DeviceSession | undefined;
  private unwatch: (() => void) | undefined;
  private abort: AbortController | undefined;
  /** The frames drawn so far, by card id, with the fingerprint of the drawing. */
  private readonly frames = new Map<string, { sig: string; frame: Uint8Array }>();
  private readonly drawing = new Map<string, Promise<Uint8Array>>();
  /** The phone's calendar from the Shortcut: in memory only, never saved. */
  private phoneData: AgendaData | undefined;

  constructor(deps: ModelDeps) {
    this.deps = deps;
  }

  /** Call `listener` after every change of `state`; returns the function that stops it. */
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private set(change: Partial<ModelState>): void {
    this.state = { ...this.state, ...change };
    for (const listener of [...this.listeners]) listener();
  }

  private setLink(change: Partial<ModelState['link']>): void {
    this.set({ link: { ...this.state.link, ...change } });
  }

  private now(): number {
    return (this.deps.now?.() ?? new Date()).getTime();
  }

  /** Read the cards and settings (and the frames drawn earlier) from the store. */
  async load(): Promise<void> {
    const { store } = this.deps;
    const [cards, settings] = await Promise.all([store.getCards(), store.getSettings()]);
    this.frames.clear();
    for (const card of cards) {
      const sig = cardSig(card, settings);
      const frame = await store.getFrame(card.id, sig).catch(() => undefined);
      if (frame) this.frames.set(card.id, { sig, frame });
    }
    this.set({ cards, settings, ready: true });
  }

  /** Show `error` to the user (a failure the views met, such as a file that could not be read). */
  reportError(error: unknown): void {
    this.set({ error });
  }

  clearError(): void {
    this.set({ error: undefined });
  }

  dismissOffer(): void {
    this.set({ offer: undefined });
  }

  // --- Settings ----------------------------------------------------------------------

  /** Keep `settings`; when the browser cannot save them, say so and keep the old ones. */
  private async saveSettings(settings: Settings): Promise<void> {
    try {
      await this.deps.store.setSettings(settings);
    } catch (error) {
      this.reportError(error);
      return;
    }
    this.set({ settings });
  }

  async setPageKind(page: number, kind: PageKind): Promise<void> {
    await this.saveSettings(setPageKind(this.state.settings, page, kind));
  }

  async setGrain(grain: number): Promise<void> {
    await this.saveSettings({ ...this.state.settings, grain });
  }

  /** 自然 / Natural, 明亮 / Bright or 經典 / Classic; leaving 經典 also sets the grain to 標準 (settings.setColours). */
  async setColours(colours: ColourMode): Promise<void> {
    await this.saveSettings(setColours(this.state.settings, colours));
  }

  /** How photos are dithered now. */
  private dithering(): Dithering {
    const { colours, grain } = this.state.settings;
    return { colours, grain };
  }

  // --- Cards -------------------------------------------------------------------------

  private async reloadCards(): Promise<void> {
    this.set({ cards: await this.deps.store.getCards() });
  }

  /** Save a new card, or a changed one (same id as a saved card); returns it as saved. */
  async saveCard(card: Card, photo?: PreparedPhoto): Promise<Card> {
    const saved = this.state.cards.some((c) => c.id === card.id)
      ? await updateCard(this.deps.store, card, photo)
      : await addCard(this.deps.store, card, photo);
    this.frames.delete(saved.id);
    await this.reloadCards();
    return saved;
  }

  async deleteCard(id: string): Promise<void> {
    await removeCard(this.deps.store, id);
    this.frames.delete(id);
    await this.reloadCards();
  }

  /** The stored photo of a card, if it has one. */
  async background(card: Card): Promise<Uint8Array | undefined> {
    return 'image' in card.background ? this.deps.store.getBackground(card.background.image) : undefined;
  }

  /** The card drawn as a frame: kept from before when nothing changed, else drawn now. */
  frameFor(card: Card): Promise<Uint8Array> {
    const sig = cardSig(card, this.state.settings);
    const kept = this.frames.get(card.id);
    if (kept?.sig === sig) return Promise.resolve(kept.frame);
    const key = `${card.id}|${sig}`;
    let pending = this.drawing.get(key);
    if (!pending) {
      pending = this.draw(card, sig).finally(() => this.drawing.delete(key));
      this.drawing.set(key, pending);
    }
    return pending;
  }

  private async draw(card: Card, sig: string): Promise<Uint8Array> {
    const cached = await this.deps.store.getFrame(card.id, sig).catch(() => undefined);
    const frame = cached ?? (await this.deps.drawCard(card, this.dithering(), await this.background(card)));
    if (!cached) await this.deps.store.setFrame(card.id, sig, frame).catch(() => undefined); // only a cache
    this.frames.set(card.id, { sig, frame });
    this.set({}); // thumbnails and "on page N" marks can use it now
    return frame;
  }

  /** The frame of `card` if it was drawn already (for thumbnails), else undefined. */
  drawnFrame(card: Card): Uint8Array | undefined {
    const kept = this.frames.get(card.id);
    return kept?.sig === cardSig(card, this.state.settings) ? kept.frame : undefined;
  }

  /** The page this app last put `card` on, if the card has not changed since. */
  pageOf(card: Card): number | undefined {
    const frame = this.drawnFrame(card);
    if (!frame) return undefined;
    const hash = frameHash(frame);
    const { lastSent, pages } = this.state.settings;
    return cardPageSlots(pages).find((slot) => lastSent[slot] === hash);
  }

  /** The saved card this app last put on page `slot`, if one of the drawn cards is that very frame. */
  cardOn(slot: number): Card | undefined {
    const sent = this.state.settings.lastSent[slot];
    if (sent === undefined) return undefined;
    return this.state.cards.find((card) => {
      const frame = this.drawnFrame(card);
      return frame !== undefined && frameHash(frame) === sent;
    });
  }

  /** Pages `slots` now show something other than a card: forget the cards this app had put there. */
  private async forgetCards(slots: Iterable<number>): Promise<void> {
    const gone = [...slots].filter((slot) => slot in this.state.settings.lastSent);
    if (gone.length === 0) return;
    // The stored settings, not the ones in memory: the Android background sync runs beside the app.
    const settings = await this.deps.store.getSettings().catch(() => this.state.settings);
    const lastSent = { ...settings.lastSent };
    for (const slot of gone) delete lastSent[slot];
    await this.saveSettings({ ...settings, lastSent });
  }

  // --- Calendar pages -----------------------------------------------------------------

  /** The calendar page of `kind` as palette indices (for previews and sending), on the photo of page `slot` if it has one. */
  async drawCalendar(kind: CalendarKind, slot?: number): Promise<Uint8Array> {
    if (!this.deps.drawCalendar) throw new Error('this app cannot draw calendar pages here');
    const { backgrounds, colours, grain } = this.state.settings;
    const background = slot === undefined ? undefined : backgrounds[slot];
    // A photo the store lost is not worth failing the page for: it is drawn without one.
    const photo = background ? await this.deps.store.getBackground(background.image) : undefined;
    return this.deps.drawCalendar(kind, this.phoneData, background && photo ? { photo, crop: background.crop, colours, grain } : undefined);
  }

  /** The stored photo behind page `slot`, if it has one. */
  async pageBackground(slot: number): Promise<Uint8Array | undefined> {
    const background = this.state.settings.backgrounds[slot];
    return background ? this.deps.store.getBackground(background.image) : undefined;
  }

  /** Put a photo on page `slot` (behind a calendar page, or as a photo page's photo), or (without `photo`) change only the crop of the one it has. */
  async setPageBackground(slot: number, crop: Crop | null, photo?: PreparedPhoto): Promise<void> {
    await setPageBackground(this.deps.store, slot, crop, photo);
    this.set({ settings: await this.deps.store.getSettings() });
  }

  async clearPageBackground(slot: number): Promise<void> {
    await clearPageBackground(this.deps.store, slot);
    this.set({ settings: await this.deps.store.getSettings() });
  }

  /** Show the calendar page that page `slot` is set to on the device. */
  async sendCalendarPage(slot: number): Promise<void> {
    const kind = this.state.settings.pages[slot];
    if (this.state.job || !CALENDAR_KINDS.includes(kind as CalendarKind)) return;
    const connecting = this.sessionNow();
    await this.run('calendar', async (signal) => {
      const frame = packIndices(await this.drawCalendar(kind as CalendarKind, slot));
      const done = await pushToPage(await connecting, slot, frame, this.options(signal));
      await this.forgetCards([slot]);
      await this.afterPush(done, { kind: 'calendar', slot, unchanged: done.results.get(slot) === 'unchanged', redraws: done.refreshing });
    });
  }

  // --- Photo pages --------------------------------------------------------------------

  /** The photo page `slot` as palette indices (for previews and sending): its photo, cut (or whole) and dithered; undefined when it has none. */
  async drawPhotoPage(slot: number): Promise<Uint8Array | undefined> {
    const { backgrounds, colours, grain } = this.state.settings;
    const background = backgrounds[slot];
    const photo = background ? await this.deps.store.getBackground(background.image) : undefined;
    if (!background || !photo) return undefined;
    if (!this.deps.drawPhoto) throw new Error('this app cannot draw photos here');
    return this.deps.drawPhoto({ photo, crop: background.crop, colours, grain, ...(background.fit ? { fit: background.fit } : {}) });
  }

  /** Show the photo of the photo page `slot` on the device. */
  async sendPhotoPage(slot: number): Promise<void> {
    const { pages, backgrounds } = this.state.settings;
    if (this.state.job || pages[slot] !== 'photo' || !backgrounds[slot]) return;
    const connecting = this.sessionNow();
    await this.run('photo', async (signal) => {
      const indices = await this.drawPhotoPage(slot);
      if (!indices) throw new Error(`the photo of page ${slot} is missing`);
      const done = await pushToPage(await connecting, slot, packIndices(indices), this.options(signal));
      await this.forgetCards([slot]);
      await this.afterPush(done, { kind: 'photo', slot, unchanged: done.results.get(slot) === 'unchanged', redraws: done.refreshing });
    });
  }

  /** Show the whole photo of page `slot` with white edges ('contain'), or fill the screen with it ('cover'); nothing without a photo. */
  async setPhotoFit(slot: number, fit: 'cover' | 'contain'): Promise<void> {
    const background = this.state.settings.backgrounds[slot];
    if (!background) return;
    const { image, crop } = background;
    const backgrounds = { ...this.state.settings.backgrounds, [slot]: fit === 'contain' ? { image, crop, fit } : { image, crop } };
    await this.saveSettings({ ...this.state.settings, backgrounds });
  }

  // --- Files -------------------------------------------------------------------------

  private prepare(): PreparePhoto {
    if (!this.deps.preparePhoto) throw new Error('this app cannot read photos here');
    return this.deps.preparePhoto;
  }

  exportCard(id: string): Promise<Uint8Array> {
    return exportCardFile(this.deps.store, id);
  }

  async importCard(bytes: Uint8Array): Promise<Card> {
    const card = await importCardFile(this.deps.store, bytes, this.prepare());
    await this.reloadCards();
    return card;
  }

  /**
   * Make the backup file and hand it to `save`, which says whether it reached the user. The time of
   * the backup is kept only then (a cancelled share sheet is no backup); returns whether it was.
   */
  async exportBackup(save: (file: Uint8Array) => Promise<boolean>): Promise<boolean> {
    const now = this.deps.now?.() ?? new Date();
    if (!(await save(await exportBackup(this.deps.store, now)))) return false;
    await this.saveSettings({ ...this.state.settings, lastBackup: now.toISOString() });
    return true;
  }

  /** Replace everything with a backup file; returns the number of cards. */
  async importBackup(bytes: Uint8Array): Promise<number> {
    const count = await importBackup(this.deps.store, bytes, this.prepare());
    await this.load();
    return count;
  }

  // --- The device --------------------------------------------------------------------

  private readonly onLink = (event: LinkEvent): void =>
    this.setLink({ activity: event.type === 'waiting' || event.type === 'attempt' ? event : undefined });

  private async openSession(): Promise<DeviceSession> {
    return this.adopt(await this.deps.connect(this.onLink));
  }

  /** Take `session` as the link to the device. */
  private adopt(session: DeviceSession): DeviceSession {
    this.unwatch?.();
    this.session = session;
    this.unwatch = session.onDisconnect((reason) => {
      if (this.session === session) this.setLink({ connected: false, activity: undefined, ...(reason === 'requested' ? { name: undefined } : {}) });
    });
    this.setLink({ connected: true, name: session.name, activity: undefined });
    void session.battery().then((battery) => this.setLink({ battery }), () => undefined);
    return session;
  }

  /** Connect (choose the device the first time), or reconnect after the link dropped. */
  async connect(): Promise<void> {
    if (this.state.job) return;
    const session = this.session;
    await this.run('connect', async () => {
      if (!session) {
        await this.openSession();
        return;
      }
      this.setLink({ battery: await session.battery(), connected: true, activity: undefined });
    });
  }

  async disconnect(): Promise<void> {
    const session = this.session;
    this.session = undefined;
    this.unwatch?.();
    this.unwatch = undefined;
    this.setLink({ connected: false, name: undefined, battery: undefined, activity: undefined });
    await session?.close();
  }

  /** Stop the job that is running, as soon as the device lets it. */
  stop(): void {
    this.abort?.abort();
  }

  /** Run `work` as the one job; errors end up in `state.error` (a NoCardPage becomes an offer). */
  private async run(kind: JobKind, work: (signal: AbortSignal) => Promise<void>, card?: Card): Promise<void> {
    const abort = new AbortController();
    this.abort = abort;
    const hold = kind === 'connect' ? undefined : this.deps.keepAwake?.();
    this.set({ job: { kind }, error: undefined, notice: undefined });
    try {
      await work(abort.signal);
    } catch (error) {
      if (error instanceof NoCardPage && card) this.set({ offer: { slot: error.suggestedSlot, card } });
      else if (!abort.signal.aborted) this.set({ error });
    } finally {
      hold?.release();
      this.abort = undefined;
      this.set({ job: undefined });
    }
  }

  private options(signal: AbortSignal) {
    return { signal, onEvent: (progress: PushEvent) => this.set({ job: { kind: this.state.job?.kind ?? 'push', progress } }) };
  }

  /** The session to push through: the one we have (it reconnects by itself), or a new one. */
  private sessionNow(): Promise<DeviceSession> {
    const connecting = this.session ? Promise.resolve(this.session) : this.openSession();
    connecting.catch(() => undefined); // reported where it is awaited
    return connecting;
  }

  private async afterPush(
    done: { lastSent?: Record<number, string>; refreshing: boolean },
    notice: NonNullable<ModelState['notice']>,
  ): Promise<void> {
    if (done.lastSent) await this.saveSettings({ ...this.state.settings, lastSent: done.lastSent });
    this.set({ notice, ...(done.refreshing ? { refreshUntil: this.now() + REFRESH_MS } : {}) });
  }

  /** Show a card on the device (see core/cardPush.ts for which page it goes to). */
  async pushCard(card: Card): Promise<void> {
    if (this.state.job) return;
    const { pages } = this.state.settings;
    if (cardPageSlots(pages).length === 0) {
      this.set({ offer: { slot: suggestedCardSlot(pages), card } });
      return;
    }
    const connecting = this.sessionNow(); // before anything is awaited: a tap that opens the chooser
    await this.run(
      'push',
      async (signal) => {
        const frame = await this.frameFor(card);
        const done = await pushCard(await connecting, this.state.settings, frame, this.options(signal));
        await this.afterPush(done, { kind: 'card', slot: done.slot, unchanged: done.results.get(done.slot) === 'unchanged', redraws: done.refreshing });
      },
      card,
    );
  }

  /**
   * 「在裝置上顯示」: put page `slot` on screen, uploading nothing. The page on screen is read first, asked
   * again while the device is busy or redrawing as a push does; the device switches only when it shows
   * another page (it has just answered, so it takes the switch at once).
   */
  async showPage(slot: number): Promise<void> {
    if (this.state.job) return;
    const connecting = this.sessionNow(); // before anything is awaited: a tap that opens the chooser
    await this.run('show', async (signal) => {
      const session = await connecting;
      const already = (await session.currentSlot({ signal })).slot === slot;
      if (!already) await session.show(slot);
      await this.afterPush({ refreshing: !already }, { kind: 'show', slot, unchanged: already, redraws: !already });
    });
  }

  /** The offer was accepted: make the page a card page and push the card. */
  async confirmOffer(): Promise<void> {
    const offer = this.state.offer;
    if (!offer) return;
    this.set({ offer: undefined });
    await this.setPageKind(offer.slot, 'card');
    await this.pushCard(offer.card);
  }

  /** Put the cards on the card pages, first on the lowest, without switching the display. */
  async preload(cards: readonly Card[]): Promise<void> {
    if (this.state.job) return;
    const connecting = this.sessionNow();
    await this.run('preload', async (signal) => {
      const frames = await Promise.all(cards.map((card) => this.frameFor(card)));
      const done = await preloadCards(await connecting, this.state.settings, frames, this.options(signal));
      await this.afterPush({ ...done, refreshing: false }, { kind: 'preload', count: cards.length });
    });
  }

  /**
   * The iPhone Shortcut opened the page with the phone's calendar: draw the calendar pages from it, find
   * the remembered device again without a tap, send the pages (the device skips the ones it already
   * holds) and say how it went. The data stays in memory; card and photo pages are left alone.
   */
  async syncFromShortcut(request: SyncRequest): Promise<void> {
    if (this.state.job) return;
    if ('unreadable' in request) {
      this.set({ sync: { outcome: 'unreadable' } });
      return;
    }
    this.phoneData = request.calendar;
    const { pages } = this.state.settings;
    const slots = USER_SLOTS.filter((slot) => CALENDAR_KINDS.includes(pages[slot] as CalendarKind));
    this.set({ phoneCalendar: true, sync: slots.length === 0 ? { outcome: 'noPages' } : undefined });
    if (slots.length === 0) return;
    const reconnect = this.deps.reconnect;
    await this.run('sync', async (signal) => {
      try {
        const frames = new Map(await Promise.all(slots.map(async (slot) => [slot, packIndices(await this.drawCalendar(pages[slot] as CalendarKind, slot))] as const)));
        let session = this.session;
        if (!session) {
          session = await reconnect?.(this.onLink, signal);
          if (!session) {
            this.set({ sync: { outcome: 'notPaired' } });
            return;
          }
          this.adopt(session);
        }
        let refreshing = false;
        const options = this.options(signal);
        const results = await session.pushPages(frames, {
          ...options,
          onEvent: (event) => {
            options.onEvent(event);
            refreshing ||= event.phase === 'refreshing';
          },
        });
        await this.forgetCards(results.keys());
        this.set({ sync: { outcome: 'done', ...summary(results) }, ...(refreshing ? { refreshUntil: this.now() + REFRESH_MS } : {}) });
      } catch (error) {
        if (signal.aborted) this.set({ sync: undefined });
        else if (error instanceof ConnectFailed) this.set({ sync: { outcome: 'notFound' } });
        else {
          const pushed = error instanceof PushFailed;
          if (pushed) await this.forgetCards(error.completed.keys());
          this.set({ sync: { outcome: 'failed', ...summary(pushed ? error.completed : new Map()), ...(pushed ? { page: error.slot } : {}) } });
          throw error; // shown with its details
        }
      }
    });
  }

  dismissSync(): void {
    this.set({ sync: undefined });
  }
}

/** The pages a push stored and the pages the device already held, in page order. */
function summary(results: ReadonlyMap<number, UploadResult>): { updated: number[]; unchanged: number[] } {
  const pages = (result: UploadResult) => [...results].filter(([, r]) => r === result).map(([slot]) => slot).sort((a, b) => a - b);
  return { updated: pages('ok'), unchanged: pages('unchanged') };
}
