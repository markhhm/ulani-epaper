/**
 * What the diagnostics page does, without the page: each step as a method
 * that updates the checklist and the log and returns what it found. The page
 * (view.ts) only wires buttons to these methods; tests drive them with fake
 * transports.
 *
 * Settings the session API does not cover (write mode, chunk size, the log)
 * are set on the transport when it has them, as WebBluetoothTransport does.
 *
 * Checklist notes come in every language (the page has a language button);
 * the log stays in English.
 */

import { createTransport } from '../ble/select';
import { type Logger, type ProtocolCharacteristic, type Transport, TransportError, type Unsubscribe } from '../ble/transport';
import type { WriteMethod, WriteModeSetting } from '../ble/webBluetooth';
import type { Battery, SlotStatus } from '../core/protocol';
import { USER_SLOTS } from '../core/protocol';
import { localize, message, same } from '../i18n';
import {
  type CalendarSession,
  connectSession,
  type ConnectSessionOptions,
  type LinkEvent,
  SESSION_DEFAULTS,
  type SessionOptions,
  type UploadResult,
} from '../session/session';
import { downloadFeed, type FeedReport, HOLIDAY_FEED_URL } from './calendarFeed';
import {
  type BrowserEnv,
  type BrowserReport,
  browserVerdicts,
  describeWriteMethods,
  deviceWriteMethodsVerdict,
  inspectBrowser,
  type Verdict,
} from './checks';
import { type CheckId, Checklist } from './checklist';
import { DroppedWhileRedrawing, explainError, isAbort, NotConnected, technicalDetail } from './errors';
import { formatBattery, formatCount, formatRate, formatSeconds, formatStamp } from './format';
import { LogBook } from './logbook';
import { testCardFrame } from './testCard';

/** Chunk sizes offered for uploads (bytes per image packet). */
export const CHUNK_SIZES: readonly number[] = Object.freeze([180, 120, 20]);
/** "Flush every" choices: read the firmware revision every N packets; 0 never. */
export const FLUSH_CHOICES: readonly number[] = Object.freeze([10, 5, 20, 0]);
export const WRITE_MODES: readonly WriteModeSetting[] = Object.freeze(['auto', 'withoutResponse', 'withResponse']);

/** How long the panel refreshes after the page on screen was replaced or switched (approximate). */
export const REFRESH_SECONDS = 40;

/**
 * A link that drops this soon after the panel started to refresh (with no
 * reply since) is the device's doing, as it does 15-25 s into a refresh: not
 * an error. The page reconnects by itself after the refresh.
 */
export const EXPECTED_DROP_MS = 60_000;

/** What (re)connecting is doing right now (see LinkEvent). */
export type LinkActivity =
  | { readonly type: 'waiting'; readonly until: number }
  | { readonly type: 'attempt'; readonly attempt: number };

export interface DeviceSummary {
  /** Advertised name, e.g. `ULANI 1A2B3C`. */
  readonly name: string | undefined;
  /** Transport kind, e.g. `web-bluetooth`. */
  readonly kind: string;
  readonly model?: string;
  readonly modelError?: unknown;
  readonly firmware?: string;
  readonly firmwareError?: unknown;
}

export interface StatusReport {
  readonly battery?: Battery;
  readonly batteryError?: unknown;
  readonly slot?: SlotStatus;
  readonly slotError?: unknown;
}

export interface UploadSettings {
  /** Page (slot) to store the card in, 1-4. */
  readonly page: number;
  readonly writeMode: WriteModeSetting;
  /** Bytes per image packet. */
  readonly chunkSize: number;
  /** Read the firmware revision every N packets; 0 never. */
  readonly flushEvery: number;
  /** Send the previous card again instead of drawing a new one. */
  readonly resend?: boolean;
}

export interface UploadProgress {
  readonly sent: number;
  readonly total: number;
  /** Since the upload started. */
  readonly elapsedMs: number;
}

export interface UploadReport {
  readonly settings: UploadSettings;
  /** `error` when it failed or was stopped (see `error`). */
  readonly outcome: UploadResult | 'error';
  readonly error?: unknown;
  /** Wall-clock start (ms since the epoch). */
  readonly startedAt: number;
  /** Printed on the card. */
  readonly stamp: string;
  readonly frameBytes: number;
  readonly sent: number;
  readonly packets: number;
  /** The packet size the session used (after clamping). */
  readonly chunkSize: number | undefined;
  /** Whether the transport took the write mode and chunk size settings. */
  readonly applied: { readonly writeMode: boolean; readonly chunkSize: boolean };
  /** Start to result. */
  readonly totalMs: number;
  /** Start to the first packet written (unlock, header, first packet). */
  readonly setupMs?: number;
  /** First to last packet. */
  readonly dataMs?: number;
  /** Last packet to the device's result. */
  readonly waitMs?: number;
  /** Bytes after the first packet divided by dataMs. */
  readonly bytesPerSecond?: number;
  /** The page was on screen when the upload started (as far as known). */
  readonly onScreen: boolean;
  /** The panel is refreshing now (the page on screen was replaced). */
  readonly refreshing: boolean;
}

export interface UploadCallbacks {
  readonly signal?: AbortSignal;
  /** The card about to be sent (packed frame) and the time printed on it. */
  readonly onCard?: (frame: Uint8Array, stamp: string) => void;
  readonly onProgress?: (progress: UploadProgress) => void;
}

export interface DiagnosticsOptions {
  /** Makes a new, unconnected transport. Default: createTransport() (src/ble/select.ts). */
  readonly createTransport?: () => Transport;
  /** Session timing; the log and onLink are always the page's. */
  readonly session?: Omit<SessionOptions, 'log' | 'onLink'>;
  /**
   * Connection attempts and pauses. Default: 3 attempts, 3 s apart, and the
   * session's defaults for the rest.
   */
  readonly connect?: Pick<
    ConnectSessionOptions,
    'attempts' | 'retryDelayMs' | 'attemptTimeoutMs' | 'connectWindowMs' | 'refreshWaitMs'
  >;
  /** Monotonic clock for durations. Default performance.now(). */
  readonly now?: () => number;
  /** Wall clock for the card's time stamp. Default Date.now(). */
  readonly wallClock?: () => number;
  readonly log?: LogBook;
  /** fetch() for the calendar download test. Default: the browser's. */
  readonly fetch?: typeof fetch;
}

/** Settings and details some transports expose (WebBluetoothTransport has them all). */
interface Tunable {
  writeMode: WriteModeSetting;
  writeLength: number | undefined;
  logger: Logger | undefined;
  writeMethods(characteristic: ProtocolCharacteristic): Readonly<Record<WriteMethod, boolean>> | undefined;
}

function has<K extends keyof Tunable>(transport: Transport, key: K): transport is Transport & Pick<Tunable, K> {
  return key in transport;
}

/**
 * One line about a calendar download, in English, for the log and the copied
 * report, e.g. `PASS, HTTP 200, 12 345 bytes, starts with BEGIN:VCALENDAR, 52 events, 0.8 s`.
 */
export function describeFeed(report: FeedReport): string {
  const time = formatSeconds(report.ms);
  if (report.outcome === 'blocked') {
    const status = report.status === undefined ? '' : ` after HTTP ${report.status}`;
    return `BLOCKED${status}: ${technicalDetail(report.error).replace(/\n/g, ' | ')} (${time})`;
  }
  const verdict = report.outcome === 'pass' ? 'PASS' : 'NOT CALENDAR DATA';
  const start = report.vcalendar ? 'starts with BEGIN:VCALENDAR' : 'does not start with BEGIN:VCALENDAR';
  const size = `${formatCount(report.bytes ?? 0)} bytes`;
  return `${verdict}, HTTP ${report.status}, ${size}, ${start}, ${report.events ?? 0} events, ${time}`;
}

/** The first page that is not on screen; page 1 when the page on screen is unknown. */
export function defaultUploadPage(shown: number | undefined): number {
  return USER_SLOTS.find((page) => page !== shown) ?? USER_SLOTS[0];
}

export class Diagnostics {
  readonly checklist = new Checklist();
  readonly log: LogBook;
  browser: BrowserReport | undefined;
  /** The last calendar download test. */
  feed: FeedReport | undefined;
  device: DeviceSummary | undefined;
  status: StatusReport | undefined;
  /** Page on screen, as last read or switched to. */
  shown: number | undefined;
  /** Every upload attempt, oldest first. */
  readonly uploads: UploadReport[] = [];
  /** Write methods of the device's image characteristic, read when connected (where the transport tells). */
  deviceWriteMethods: Readonly<Record<WriteMethod, boolean>> | undefined;
  /** What (re)connecting is doing right now; undefined while it is not. */
  linkActivity: LinkActivity | undefined;
  /**
   * The device dropped a connection attempt before notifications were on:
   * show the pairing-mode hint (until a connection works).
   */
  pairingHint = false;
  /** Why the page's own reconnect after a panel refresh failed; cleared once connected. */
  reconnectError: unknown;
  /**
   * When the panel last started to refresh (a Date.now() time), after the
   * page was switched or the page on screen replaced; kept after the refresh.
   */
  refreshStartedAt: number | undefined;

  private readonly options: DiagnosticsOptions;
  private readonly now: () => number;
  private readonly wallClock: () => number;
  private transport: Transport | undefined;
  private sessionNow: CalendarSession | undefined;
  private unwatch: Unsubscribe | undefined;
  private lastCard: { frame: Uint8Array; stamp: string } | undefined;
  private reconnecting: { readonly controller: AbortController; readonly done: Promise<void> } | undefined;
  /** The latest connect(); link events of sessions made before it are ignored. */
  private linkOwner: object | undefined;
  private readonly listeners = new Set<() => void>();

  constructor(options: DiagnosticsOptions = {}) {
    this.options = options;
    this.log = options.log ?? new LogBook();
    this.now = options.now ?? (() => performance.now());
    this.wallClock = options.wallClock ?? (() => Date.now());
  }

  /** The open session, if connect() succeeded and disconnect() has not run since. */
  get session(): CalendarSession | undefined {
    return this.sessionNow;
  }

  /** Whether the Bluetooth link is up right now. */
  get connected(): boolean {
    return this.transport?.connected ?? false;
  }

  /** Whether a card was sent before (so `resend` has something to send). */
  get hasPreviousCard(): boolean {
    return this.lastCard !== undefined;
  }

  /**
   * When the last panel refresh should be over: when the page reconnects if
   * the device dropped the link meanwhile (the session's refreshWaitMs after
   * it started), so the refresh note and the link line count to the same time.
   */
  get refreshEndsAt(): number | undefined {
    return this.refreshStartedAt === undefined ? undefined : this.refreshStartedAt + this.refreshWaitMs();
  }

  /** The sessions' refreshWaitMs, merged as connect() merges the options. */
  private refreshWaitMs(): number {
    return (
      this.options.session?.refreshWaitMs ?? this.options.connect?.refreshWaitMs ?? SESSION_DEFAULTS.refreshWaitMs
    );
  }

  /**
   * Settles when the page's own reconnect after a panel refresh is over
   * (connected, failed or stopped); at once when none is running. Never rejects.
   */
  reconnection(): Promise<void> {
    return this.reconnecting?.done ?? Promise.resolve();
  }

  /** Called when the connection, the device or the page on screen changes. */
  onChange(listener: () => void): Unsubscribe {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  // --- Step 1: the browser ----------------------------------------------------------

  async checkBrowser(env?: BrowserEnv): Promise<BrowserReport> {
    for (const id of ['webBluetooth', 'availability', 'secureContext', 'writeMethods'] as const) {
      this.checklist.set(id, 'running');
    }
    const report = await inspectBrowser(env);
    this.browser = report;
    const verdicts = browserVerdicts(report);
    // Once connected, the device's characteristic answered the write methods check.
    if (this.deviceWriteMethods) verdicts.writeMethods = deviceWriteMethodsVerdict(this.deviceWriteMethods);
    for (const [id, verdict] of Object.entries(verdicts) as [CheckId, Verdict][]) {
      this.checklist.set(id, verdict.status, verdict.note);
    }
    const methods = report.writeMethods
      ? Object.entries(report.writeMethods)
          .map(([name, present]) => `${name}=${present ? 'yes' : 'no'}`)
          .join(', ')
      : 'no BluetoothRemoteGATTCharacteristic';
    this.log.add(
      'info',
      `browser: bluetooth=${report.webBluetooth ? 'yes' : 'no'}, availability=${report.availability}` +
        `${report.availabilityError ? ` (${report.availabilityError})` : ''}, ` +
        `secureContext=${String(report.secureContext)} (${report.protocol}), ${methods}`,
    );
    this.log.add('info', `user agent: ${report.userAgent}`);
    return report;
  }

  // --- Step 2: calendar download ----------------------------------------------------

  /**
   * Download the public holidays feed straight from its source (no
   * credentials, no proxy): PASS when calendar data came back, FAIL when the
   * browser blocked it or the answer was not calendar data. Never rejects.
   */
  async downloadCalendar(): Promise<FeedReport> {
    this.checklist.set('calendarFeed', 'running');
    this.log.add('info', `calendar download: GET ${HOLIDAY_FEED_URL} (no credentials, no proxy)`);
    const report = await downloadFeed({ fetch: this.options.fetch, now: this.now });
    this.feed = report;
    const line = describeFeed(report);
    const size = `${formatCount(report.bytes ?? 0)} bytes`;
    switch (report.outcome) {
      case 'pass':
        this.checklist.set('calendarFeed', 'pass', `HTTP ${report.status}, ${size}, BEGIN:VCALENDAR`);
        this.log.add('info', `calendar download: ${line}`);
        break;
      case 'unexpected':
        this.checklist.set(
          'calendarFeed',
          'fail',
          `HTTP ${report.status}, ${size}, ${report.vcalendar ? 'BEGIN:VCALENDAR' : 'no BEGIN:VCALENDAR'}`,
        );
        this.log.add('warn', `calendar download: ${line}`);
        break;
      case 'blocked':
        this.checklist.set('calendarFeed', 'fail', `BLOCKED: ${technicalDetail(report.error).split('\n')[0]}`);
        this.log.add('error', `calendar download: ${line}`);
        break;
    }
    this.changed();
    return report;
  }

  // --- Step 3: connect --------------------------------------------------------------

  /**
   * Choose a device, connect, enable notifications and unlock, then read
   * the model and firmware. Call it straight from a click: everything up to
   * the browser's device chooser runs synchronously.
   *
   * @throws whatever connectSession throws (see session.ts).
   */
  connect(): Promise<DeviceSummary> {
    const previous = this.sessionNow;
    this.sessionNow = undefined;
    this.stopReconnecting();
    this.unwatch?.();
    // Close a link the previous session still holds (its reconnect may be
    // unlocking it), synchronously so the click still counts: Chrome gives
    // both transports the same device and so the same GATT server.
    void previous?.transport.disconnect();
    // Progress of the sessions made before this connect no longer counts.
    const owner = {};
    this.linkOwner = owner;
    const onLink = (event: LinkEvent) => {
      if (this.linkOwner === owner) this.onLink(event);
    };
    const transport = (this.options.createTransport ?? createTransport)();
    this.transport = transport;
    if (has(transport, 'logger')) transport.logger = this.log.logger;
    this.unwatch = transport.onDisconnect((reason) => {
      if (reason === 'lost') this.linkDropped();
      this.changed();
    });
    for (const id of ['connect', 'deviceInfo', 'disconnect'] as const) this.checklist.set(id, 'pending');
    this.checklist.set('connect', 'running');
    this.log.add('info', `connect (${transport.kind})`);
    const connecting = connectSession(transport, {
      attempts: 3,
      retryDelayMs: 3_000,
      ...this.options.connect,
      ...this.options.session,
      log: this.log.logger,
      onLink,
    });
    // After the chooser opened: the earlier session (link down by now) lets go of its listeners.
    void previous?.close();
    return connecting.then(
      (session) => this.finishConnect(session, transport),
      (error: unknown) => {
        this.fail('connect', 'connect', error);
        this.changed();
        throw error;
      },
    );
  }

  private async finishConnect(session: CalendarSession, transport: Transport): Promise<DeviceSummary> {
    this.sessionNow = session;
    this.checklist.set('connect', 'pass', transport.deviceName ?? '');
    this.log.add('info', `connected to ${transport.deviceName ?? '(no name)'}`);
    this.changed();

    this.checklist.set('deviceInfo', 'running');
    const device: { -readonly [K in keyof DeviceSummary]: DeviceSummary[K] } = {
      name: transport.deviceName,
      kind: transport.kind,
    };
    try {
      device.model = await session.model();
    } catch (error) {
      device.modelError = error;
    }
    try {
      device.firmware = await session.firmware();
    } catch (error) {
      device.firmwareError = error;
    }
    const parts = [device.model ?? '?', device.firmware ?? '?'].join(', ');
    if (device.modelError === undefined && device.firmwareError === undefined) {
      this.checklist.set('deviceInfo', 'pass', parts);
    } else {
      const error = device.firmwareError ?? device.modelError;
      const note = device.firmwareError === undefined ? same(parts) : message('note.firmwareUnreadable', { parts });
      this.checklist.set('deviceInfo', device.model === undefined && device.firmware === undefined ? 'fail' : 'warn', note);
      this.log.add('warn', `device information: ${technicalDetail(error)}`);
    }
    this.log.add('info', `model ${device.model ?? '?'}, firmware ${device.firmware ?? '?'}`);
    this.device = device;
    this.checkDeviceWriteMethods(transport);
    this.changed();
    return device;
  }

  /**
   * The write methods of the device's image characteristic, where the
   * transport tells: what uploads really use, so its verdict replaces the
   * browser check (some browsers, such as Bluefy, expose no class to inspect).
   */
  private checkDeviceWriteMethods(transport: Transport): void {
    if (!has(transport, 'writeMethods')) return;
    const methods = transport.writeMethods('image');
    if (!methods) return;
    this.deviceWriteMethods = methods;
    const verdict = deviceWriteMethodsVerdict(methods);
    this.checklist.set('writeMethods', verdict.status, verdict.note);
    this.log.add('info', `image characteristic write methods: ${describeWriteMethods(methods)}`);
  }

  /** Progress of (re)connecting, from the session of the latest connect(). */
  private onLink(event: LinkEvent): void {
    switch (event.type) {
      case 'waiting':
      case 'attempt':
        this.linkActivity = event;
        break;
      case 'failed':
        // Only while connecting for the first time: a reconnect means this phone is paired.
        if (event.droppedWhileConnecting && this.sessionNow === undefined) this.pairingHint = true;
        break;
      case 'connected':
        this.linkActivity = undefined;
        this.pairingHint = false;
        this.reconnectError = undefined;
        break;
      case 'gaveUp':
        this.linkActivity = undefined;
        break;
    }
    this.changed();
  }

  /**
   * The link dropped. Shortly after the panel started to refresh (with no
   * reply since) that is the device's doing and expected: reconnect once
   * the refresh should be over. Otherwise the next action reconnects.
   */
  private linkDropped(): void {
    const session = this.sessionNow;
    const started = this.refreshStartedAt;
    const expected =
      session !== undefined && session.refreshing && started !== undefined && Date.now() - started < EXPECTED_DROP_MS;
    if (!expected) {
      this.log.add('warn', 'the link dropped; the next action reconnects');
      return;
    }
    this.log.add('info', 'the device dropped the link while redrawing its screen, as expected; reconnecting after the refresh');
    this.reconnectAfterRefresh(session);
  }

  private reconnectAfterRefresh(session: CalendarSession): void {
    this.stopReconnecting();
    const controller = new AbortController();
    const current = () => this.sessionNow === session && !controller.signal.aborted;
    const done = session
      .start(controller.signal)
      .then(
        () => {
          if (current()) this.log.add('info', 'reconnected after the refresh');
        },
        (error: unknown) => {
          if (!current()) return;
          this.reconnectError = error;
          this.log.add(
            'warn',
            `reconnecting after the refresh failed: ${technicalDetail(error).replace(/\n/g, ' | ')}; the next action tries again`,
          );
        },
      )
      .finally(() => {
        if (this.reconnecting?.controller === controller) this.reconnecting = undefined;
        this.changed();
      });
    this.reconnecting = { controller, done };
  }

  private stopReconnecting(): void {
    this.reconnecting?.controller.abort();
    this.reconnecting = undefined;
    this.linkActivity = undefined;
  }

  /** The page on screen was switched or replaced: remember when the panel started to refresh. */
  private refreshStarted(session: CalendarSession, page: number): void {
    this.refreshStartedAt = session.refreshStartedAt ?? Date.now();
    this.log.add(
      'info',
      `page ${page} is on screen: the device redraws its screen now (about ${REFRESH_SECONDS} s) ` +
        'and may drop the link meanwhile; it reconnects by itself',
    );
  }

  // --- Step 4: status ---------------------------------------------------------------

  /** Battery and the page on screen. Each failure is reported in the result; never rejects. */
  async readStatus(): Promise<StatusReport> {
    const session = this.requireSession();
    const status: { -readonly [K in keyof StatusReport]: StatusReport[K] } = {};
    this.checklist.set('battery', 'running');
    try {
      status.battery = await session.battery();
      const battery = status.battery;
      this.checklist.set('battery', 'pass', localize((locale) => formatBattery(battery, locale)));
      this.log.add('info', `battery: ${formatBattery(status.battery)}`);
    } catch (error) {
      status.batteryError = this.expectedDrop(error);
      this.fail('battery', 'battery', status.batteryError);
    }
    this.checklist.set('page', 'running');
    try {
      status.slot = await session.currentSlot();
      this.shown = status.slot.slot;
      this.checklist.set('page', 'pass', message('page.n', { page: status.slot.slot }));
      this.log.add('info', `page on screen: ${status.slot.slot}`);
    } catch (error) {
      status.slotError = this.expectedDrop(error);
      this.fail('page', 'page on screen', status.slotError);
    }
    this.status = status;
    this.changed();
    return status;
  }

  // --- Step 5: switch page ----------------------------------------------------------

  async showPage(page: number): Promise<void> {
    const session = this.requireSession();
    this.checklist.set('switch', 'running');
    this.log.add('info', `show page ${page}`);
    try {
      await session.show(page);
    } catch (error) {
      const failure = this.expectedDrop(error);
      this.fail('switch', `show page ${page}`, failure);
      throw failure;
    }
    this.shown = page;
    this.checklist.set('switch', 'pass', message('page.n', { page }));
    this.refreshStarted(session, page);
    this.changed();
  }

  // --- Step 6: upload the test card -------------------------------------------------

  /**
   * Draw a card for `settings.page` (or take the previous one with
   * `resend`) and upload it with the given settings. Failures come back as
   * outcome `error`; it rejects only with NotConnected.
   */
  async sendTestCard(settings: UploadSettings, callbacks: UploadCallbacks = {}): Promise<UploadReport> {
    const session = this.requireSession();
    const transport = session.transport;
    const startedAt = this.wallClock();
    const card =
      settings.resend && this.lastCard
        ? this.lastCard
        : (() => {
            const stamp = formatStamp(new Date(startedAt));
            return { stamp, frame: testCardFrame({ page: settings.page, stamp }) };
          })();
    this.lastCard = card;
    callbacks.onCard?.(card.frame, card.stamp);

    const applied = { writeMode: false, chunkSize: false };
    if (has(transport, 'writeMode')) {
      transport.writeMode = settings.writeMode;
      applied.writeMode = true;
    }
    if (has(transport, 'writeLength')) {
      transport.writeLength = settings.chunkSize;
      applied.chunkSize = true;
    }
    session.options = { ...session.options, flushEvery: settings.flushEvery };
    const chunkSize = applied.chunkSize ? await session.chunkSize() : undefined;
    const onScreen = this.shown === settings.page;

    this.checklist.set('upload', 'running');
    this.log.add(
      'info',
      `upload ${settings.resend ? 'the previous card' : `a new card (${card.stamp})`} to page ${settings.page}: ` +
        `write mode ${settings.writeMode}${applied.writeMode ? '' : ' (not supported by this transport)'}, ` +
        `${settings.chunkSize}-byte packets${applied.chunkSize ? '' : ' (not supported by this transport)'}, ` +
        `flush every ${settings.flushEvery || 'never'}${onScreen ? ', page on screen' : ''}`,
    );

    const t0 = this.now();
    let first: number | undefined;
    let firstBytes = 0;
    let last: number | undefined;
    let sent = 0;
    let packets = 0;
    let outcome: UploadReport['outcome'];
    let failure: unknown;
    try {
      outcome = await session.upload(card.frame, settings.page, {
        signal: callbacks.signal,
        onProgress: (bytes, total) => {
          const time = this.now();
          if (first === undefined) {
            first = time;
            firstBytes = bytes;
          }
          last = time;
          sent = bytes;
          packets++;
          callbacks.onProgress?.({ sent: bytes, total, elapsedMs: time - t0 });
        },
      });
    } catch (error) {
      outcome = 'error';
      failure = this.expectedDrop(error);
    }
    const end = this.now();

    const dataMs = first !== undefined && last !== undefined && packets > 1 ? last - first : undefined;
    const report: UploadReport = {
      settings,
      outcome,
      ...(failure === undefined ? {} : { error: failure }),
      startedAt,
      stamp: card.stamp,
      frameBytes: card.frame.length,
      sent,
      packets,
      chunkSize,
      applied,
      totalMs: end - t0,
      ...(first === undefined ? {} : { setupMs: first - t0 }),
      ...(dataMs === undefined ? {} : { dataMs }),
      ...(last === undefined || outcome === 'error' ? {} : { waitMs: end - last }),
      ...(dataMs !== undefined && dataMs > 0 ? { bytesPerSecond: ((sent - firstBytes) * 1000) / dataMs } : {}),
      onScreen,
      refreshing: session.refreshing,
    };
    if (report.outcome === 'ok' && report.refreshing) this.refreshStartedAt = session.refreshStartedAt ?? Date.now();
    this.uploads.push(report);
    this.recordUpload(report);
    this.changed();
    return report;
  }

  private recordUpload(report: UploadReport): void {
    const page = report.settings.page;
    if (report.outcome === 'error') {
      if (isAbort(report.error)) {
        this.checklist.set(
          'upload',
          'warn',
          message('note.uploadStopped', { sent: formatCount(report.sent), total: formatCount(report.frameBytes) }),
        );
        this.log.add('warn', `upload to page ${page} stopped after ${formatCount(report.sent)} bytes`);
      } else {
        this.fail('upload', `upload to page ${page}`, report.error);
      }
      return;
    }
    if (report.outcome === 'unchanged') {
      // Nothing was sent: keep an earlier PASS.
      if (this.checklist.get('upload').status !== 'pass') {
        this.checklist.set('upload', 'warn', message('note.uploadUnchanged', { page }));
      }
      this.log.add('info', `page ${page} already holds this card (unchanged) after ${formatSeconds(report.totalMs)}`);
      return;
    }
    const speed = report.bytesPerSecond === undefined ? '' : `, ${formatRate(report.bytesPerSecond)}`;
    const details = `${formatSeconds(report.totalMs)}${speed}`;
    this.checklist.set('upload', 'pass', message('note.uploadOk', { page, details }));
    this.log.add(
      'info',
      `upload to page ${page} OK: total ${formatSeconds(report.totalMs)}, data ${formatSeconds(report.dataMs ?? 0)}` +
        `${speed}, ${report.packets} packets of ${report.chunkSize ?? '?'} bytes` +
        (report.refreshing ? `; the panel refreshes now (about ${REFRESH_SECONDS} s)` : ''),
    );
  }

  // --- Step 7: disconnect -----------------------------------------------------------

  /** Say goodbye and disconnect. Never rejects. */
  async disconnect(): Promise<void> {
    const session = this.sessionNow;
    if (!session) {
      this.log.add('info', 'disconnect: not connected');
      return;
    }
    this.sessionNow = undefined;
    this.stopReconnecting();
    this.checklist.set('disconnect', 'running');
    this.log.add('info', 'disconnect');
    await session.close();
    this.unwatch?.();
    this.unwatch = undefined;
    this.checklist.set('disconnect', session.transport.connected ? 'fail' : 'pass');
    this.changed();
  }

  // --- Helpers ------------------------------------------------------------------------

  private requireSession(): CalendarSession {
    if (!this.sessionNow) throw new NotConnected('not connected');
    return this.sessionNow;
  }

  /**
   * `error` as DroppedWhileRedrawing when it is the link the device dropped
   * while redrawing its screen and the page's own reconnect is running (see
   * linkDropped): then it is no failure, and "tap Connect" would only cancel
   * that reconnect. Anything else as it is.
   */
  private expectedDrop(error: unknown): unknown {
    if (this.reconnecting === undefined) return error;
    if (!(error instanceof TransportError) || error.code !== 'linkLost' || error.droppedWhileConnecting) return error;
    return new DroppedWhileRedrawing('the device dropped the link while redrawing its screen; the page reconnects by itself', {
      cause: error,
    });
  }

  /** A check that did not pass: WARN when it was stopped or cut off by the expected drop, else FAIL. */
  private fail(id: CheckId, what: string, error: unknown): void {
    const expected = error instanceof DroppedWhileRedrawing;
    const status = isAbort(error) || expected ? 'warn' : 'fail';
    this.checklist.set(id, status, localize((locale) => explainError(error, locale).message));
    this.log.add(expected ? 'warn' : 'error', `${what} failed: ${technicalDetail(error).replace(/\n/g, ' | ')}`);
  }

  private changed(): void {
    for (const listener of [...this.listeners]) {
      try {
        listener();
      } catch {
        // A broken view must not break the diagnostics.
      }
    }
  }
}
