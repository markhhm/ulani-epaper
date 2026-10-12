/**
 * The diagnostics page itself: a top bar with the language button, a
 * checklist, seven steps and the log, wired to a Diagnostics instance.
 * Text is in Traditional Chinese or English (src/i18n.ts) and follows the
 * language button at once; technical details and the log stay in English.
 * Buttons are large enough for a thumb.
 */

import type { WriteModeSetting } from '../ble/webBluetooth';
import { previewFrame } from '../core/frame';
import { HEIGHT, USER_SLOTS, WIDTH } from '../core/protocol';
import { getLocale, htmlLang, onLocaleChange, otherLocale, type StringKey, t, toggleLocale } from '../i18n';
import { keepAwakeMethod, keepScreenOn } from '../keepAwake';
import { FEED_EXPLANATIONS, type FeedReport, HOLIDAY_FEED_URL } from './calendarFeed';
import type { BrowserReport } from './checks';
import { checkName, statusLabel } from './checklist';
import type { WriteMethod } from './checks';
import {
  CHUNK_SIZES,
  defaultUploadPage,
  type DeviceSummary,
  type Diagnostics,
  FLUSH_CHOICES,
  type StatusReport,
  type UploadProgress,
  type UploadReport,
  WRITE_MODES,
} from './diagnostics';
import { type Child, h, setChildren } from './dom';
import { explainError, isAbort, technicalDetail } from './errors';
import { formatBattery, formatCount, formatCrc, formatRate, formatSeconds, formatStamp, percent } from './format';
import { linkStatus, reconnectErrorChange, refreshNote } from './linkStatus';
import { formatLogLine } from './logbook';
import { buildReport } from './report';
import { testCardFrame } from './testCard';

type Tone = 'pass' | 'fail' | 'warn' | 'neutral';

/** A string key, or a function that builds the text in the current language. */
type Label = StringKey | (() => string);

interface ErrorBox {
  readonly element: HTMLElement;
  show(error: unknown): void;
  clear(): void;
}

interface Rows {
  readonly element: HTMLElement;
  /** `value` runs now and again whenever the language changes. */
  set(key: string, value: () => Child, tone?: Tone): void;
}

interface Choices<T extends string | number> {
  readonly element: HTMLElement;
  readonly value: T;
  set(value: T): void;
  /** The element after each option's label, for marks such as "on screen". */
  mark(value: T): HTMLElement | undefined;
}

// --- Building blocks ------------------------------------------------------------------

/**
 * Builds the page's parts and re-renders their text when the language
 * changes. Parts are built once; text that depends on what the page found
 * is re-rendered by its owner through onLocale().
 */
class Ui {
  private readonly renderers: (() => void)[] = [];

  /** Call `render` on every language change; returns it, to call when the content changes. */
  onLocale(render: () => void): () => void {
    this.renderers.push(render);
    return render;
  }

  /** Re-render every text on the page in the current language. */
  rerender(): void {
    for (const render of this.renderers) render();
  }

  /** A text node that follows the language. */
  text(label: Label): Text {
    const read = () => (typeof label === 'function' ? label() : t(label));
    const node = document.createTextNode(read());
    this.onLocale(() => {
      node.data = read();
    });
    return node;
  }

  button(label: Label, onClick: () => void, kind: 'primary' | 'secondary' | 'danger' = 'secondary'): HTMLButtonElement {
    return h('button', { type: 'button', class: `btn btn-${kind}`, onClick }, this.text(label));
  }

  step(number: number, title: StringKey, ...body: Child[]): HTMLElement {
    return h(
      'section',
      { class: 'card step', 'aria-labelledby': `step-${number}` },
      h('h2', { id: `step-${number}` }, h('span', { class: 'step-number' }, String(number)), h('span', null, this.text(title))),
      ...body,
    );
  }

  note(label: Label, kind: 'info' | 'warn' = 'info'): HTMLElement {
    return h('p', { class: `note note-${kind}` }, this.text(label));
  }

  errorBox(): ErrorBox {
    const element = h('div', { class: 'error', role: 'alert', hidden: true });
    let shown: { error: unknown } | undefined;
    const render = this.onLocale(() => {
      if (!shown) {
        setChildren(element);
        element.hidden = true;
        return;
      }
      const explained = explainError(shown.error);
      setChildren(
        element,
        h('p', { class: 'error-message' }, explained.message),
        h('pre', { class: 'error-detail', lang: 'en' }, explained.detail),
      );
      element.hidden = false;
    });
    return {
      element,
      show(error) {
        shown = { error };
        render();
      },
      clear() {
        shown = undefined;
        render();
      },
    };
  }

  rows(defs: readonly (readonly [key: string, label: StringKey])[]): Rows {
    const cells = new Map<string, HTMLElement>();
    const values = new Map<string, () => Child>();
    const element = h(
      'dl',
      { class: 'rows' },
      defs.map(([key, label]) => {
        const cell = h('dd', null, '—');
        cells.set(key, cell);
        return h('div', { class: 'row' }, h('dt', null, this.text(label)), cell);
      }),
    );
    const fill = (key: string) => {
      const cell = cells.get(key);
      const value = values.get(key);
      if (cell && value) setChildren(cell, value());
    };
    this.onLocale(() => {
      for (const key of values.keys()) fill(key);
    });
    return {
      element,
      set(key, value, tone = 'neutral') {
        const cell = cells.get(key);
        if (!cell) return;
        cell.className = `tone-${tone}`;
        values.set(key, value);
        fill(key);
      },
    };
  }

  choices<T extends string | number>(
    name: string,
    legend: Label,
    options: readonly { readonly value: T; readonly label: Label }[],
    initial: T,
    onChange?: (value: T) => void,
  ): Choices<T> {
    let current = initial;
    const inputs = new Map<T, HTMLInputElement>();
    const marks = new Map<T, HTMLElement>();
    const element = h(
      'fieldset',
      { class: 'choices' },
      h('legend', null, this.text(legend)),
      h(
        'div',
        { class: 'chips' },
        options.map((option) => {
          const input = h('input', { type: 'radio', name, value: String(option.value) });
          input.checked = option.value === initial;
          input.addEventListener('change', () => {
            if (!input.checked) return;
            current = option.value;
            onChange?.(option.value);
          });
          inputs.set(option.value, input);
          const mark = h('small', { class: 'chip-mark' });
          marks.set(option.value, mark);
          return h('label', { class: 'chip' }, input, h('span', { class: 'chip-face' }, this.text(option.label), mark));
        }),
      ),
    );
    return {
      element,
      get value() {
        return current;
      },
      set(value) {
        current = value;
        for (const [optionValue, input] of inputs) input.checked = optionValue === value;
      },
      mark: (value) => marks.get(value),
    };
  }
}

function yesNo(value: boolean, yes: StringKey = 'value.present', no: StringKey = 'value.absent'): string {
  return t(value ? yes : no);
}

/** The first line of an error's technical message. */
function firstLine(error: unknown): string {
  return technicalDetail(error).split('\n')[0] ?? '';
}

// --- The page ---------------------------------------------------------------------------

/** Build the page inside `root` (replacing what is there) and run the browser check once. */
export function mountSpike(root: HTMLElement, diagnostics: Diagnostics): void {
  const ui = new Ui();
  const state = {
    busy: false,
    upload: undefined as AbortController | undefined,
    pagePicked: false,
    flushPicked: false,
    /** Ticks every second while a countdown is on the page. */
    ticker: undefined as ReturnType<typeof setInterval> | undefined,
  };
  /** Buttons that run an operation; `session`: only with a session. */
  const actions: { readonly button: HTMLButtonElement; readonly needs: 'nothing' | 'session' }[] = [];

  function action(control: HTMLButtonElement, needs: 'nothing' | 'session'): HTMLButtonElement {
    actions.push({ button: control, needs });
    return control;
  }

  /** Run `task` (started synchronously, so a click still counts as a user gesture). */
  function run(task: () => Promise<unknown>, errors: ErrorBox): void {
    if (state.busy) return;
    errors.clear();
    setBusy(true);
    let pending: Promise<unknown>;
    try {
      pending = task();
    } catch (error) {
      pending = Promise.reject(error);
    }
    pending
      .catch((error: unknown) => {
        errors.show(error);
      })
      .finally(() => setBusy(false));
  }

  // --- Top bar: title and the language button ---

  const languageLabel = h('span');
  const languageButton = h('button', { type: 'button', class: 'lang-toggle', onClick: () => toggleLocale() }, languageLabel);
  ui.onLocale(() => {
    const locale = getLocale();
    setChildren(languageLabel, t('language.other'));
    languageLabel.lang = htmlLang(otherLocale(locale));
    languageButton.title = t('language.otherTitle');
    document.documentElement.lang = htmlLang(locale);
    document.title = t('title.diagnostics');
  })();

  const header = h(
    'header',
    { class: 'page-header' },
    h('div', { class: 'topbar' }, h('h1', null, ui.text('diag.heading')), languageButton),
    h('p', { class: 'intro' }, ui.text('diag.intro')),
    h('p', null, h('a', { href: './index.html' }, ui.text('backToApp'))),
  );

  // --- Link state and checklist ---

  const linkState = h('p', { class: 'link-state', role: 'status' });
  const summary = h('p', { class: 'summary' });
  const checklist = h('ol', { class: 'checklist' });

  function renderChecklist(): void {
    const locale = getLocale();
    setChildren(
      checklist,
      diagnostics.checklist.entries().map((check) =>
        h(
          'li',
          { class: `check check-${check.status}` },
          h('span', { class: `badge badge-${check.status}` }, statusLabel(check.status)),
          h(
            'span',
            { class: 'check-text' },
            checkName(check.id),
            check.note[locale] ? h('span', { class: 'check-note' }, check.note[locale]) : null,
          ),
        ),
      ),
    );
    setChildren(summary, diagnostics.checklist.summary());
  }
  ui.onLocale(renderChecklist);

  // --- Step 1: browser ---

  const browserRows = ui.rows([
    ['bluetooth', 'browser.row.bluetooth'],
    ['availability', 'browser.row.availability'],
    ['secure', 'browser.row.secure'],
    ['methods', 'browser.row.methods'],
    ['agent', 'browser.row.agent'],
  ]);
  const browserErrors = ui.errorBox();

  function showBrowser(report: BrowserReport): void {
    browserRows.set('bluetooth', () => yesNo(report.webBluetooth), report.webBluetooth ? 'pass' : 'fail');
    const availability: Record<BrowserReport['availability'], [StringKey, Tone]> = {
      yes: ['browser.availability.yes', 'pass'],
      no: ['browser.availability.no', 'fail'],
      missing: ['browser.availability.missing', 'warn'],
      timeout: ['browser.availability.timeout', 'warn'],
      error: ['browser.availability.error', 'warn'],
    };
    const [key, tone] = availability[report.availability];
    browserRows.set('availability', () => t(key, { error: report.availabilityError ?? '' }), tone);
    browserRows.set(
      'secure',
      () =>
        `${report.secureContext === undefined ? t('value.unknown') : yesNo(report.secureContext, 'value.true', 'value.false')} (${report.protocol || '?'})`,
      report.secureContext ? 'pass' : report.secureContext === false ? 'fail' : 'warn',
    );
    lastBrowser = report;
    renderMethods();
    browserRows.set('agent', () => h('code', { class: 'agent' }, report.userAgent || '?'));
  }

  let lastBrowser: BrowserReport | undefined;

  /**
   * The write methods: the device characteristic's once connected (what
   * uploads use), otherwise the browser's class; some browsers (Bluefy)
   * have no class to inspect, and then connecting tells.
   */
  function renderMethods(): void {
    const device = diagnostics.deviceWriteMethods;
    const methods = device ?? lastBrowser?.writeMethods;
    if (!methods) {
      if (lastBrowser) browserRows.set('methods', () => t('browser.methodsAfterConnect'), 'neutral');
      return;
    }
    const list = (entries: Readonly<Record<WriteMethod, boolean>>) =>
      h(
        'ul',
        { class: 'methods' },
        Object.entries(entries).map(([name, present]) =>
          h('li', { class: present ? 'tone-pass' : 'tone-fail' }, `${present ? '✓' : '✗'} ${name}`),
        ),
      );
    const tone: Tone = methods.writeValueWithoutResponse ? 'pass' : 'warn';
    if (device) {
      browserRows.set('methods', () => [list(device), h('small', { class: 'muted' }, t('browser.methodsFromDevice'))], tone);
    } else {
      browserRows.set('methods', () => list(methods), tone);
    }
  }

  function checkBrowser(): void {
    run(() => diagnostics.checkBrowser().then(showBrowser), browserErrors);
  }

  const stepBrowser = ui.step(
    1,
    'browser.title',
    browserRows.element,
    action(ui.button('browser.checkAgain', checkBrowser), 'nothing'),
    browserErrors.element,
  );

  // --- Step 2: calendar download (no Bluetooth) ---

  const feedRows = ui.rows([
    ['result', 'feed.row.result'],
    ['status', 'feed.row.status'],
    ['size', 'feed.row.size'],
    ['format', 'feed.row.format'],
    ['time', 'feed.row.time'],
  ]);
  feedRows.element.hidden = true;
  const feedExplanation = h('p', { class: 'note', role: 'status', hidden: true });
  const feedDetail = h('pre', { class: 'error-detail', lang: 'en', hidden: true });
  const feedErrors = ui.errorBox();
  let lastFeed: FeedReport | undefined;

  const renderFeedExplanation = ui.onLocale(() => {
    if (!lastFeed) return;
    feedExplanation.className = `note note-${lastFeed.outcome === 'pass' ? 'info' : 'warn'}`;
    setChildren(feedExplanation, t(FEED_EXPLANATIONS[lastFeed.outcome], { status: lastFeed.status ?? '?' }));
    feedExplanation.hidden = false;
  });

  function showFeed(report: FeedReport): void {
    lastFeed = report;
    feedRows.element.hidden = false;
    feedRows.set('result', () => t(`feed.result.${report.outcome}`), report.outcome === 'pass' ? 'pass' : 'fail');
    const status = report.status;
    feedRows.set(
      'status',
      () => (status === undefined ? '—' : String(status)),
      status === undefined ? 'neutral' : status >= 200 && status < 300 ? 'pass' : 'fail',
    );
    const bytes = report.bytes;
    feedRows.set('size', () => (bytes === undefined ? '—' : t('feed.size', { bytes: formatCount(bytes) })));
    feedRows.set(
      'format',
      () =>
        report.vcalendar === undefined
          ? '—'
          : report.vcalendar
            ? t('feed.format.ok', { events: report.events ?? 0 })
            : t('feed.format.bad'),
      report.vcalendar ? 'pass' : report.vcalendar === false ? 'fail' : 'neutral',
    );
    feedRows.set('time', () => formatSeconds(report.ms));
    renderFeedExplanation();
    feedDetail.hidden = report.outcome !== 'blocked';
    setChildren(feedDetail, report.outcome === 'blocked' ? technicalDetail(report.error) : '');
  }

  const stepFeed = ui.step(
    2,
    'feed.title',
    ui.note('feed.intro'),
    h('p', { class: 'feed-url' }, h('code', { lang: 'en' }, HOLIDAY_FEED_URL)),
    action(
      ui.button('feed.button', () => run(() => diagnostics.downloadCalendar().then(showFeed), feedErrors), 'primary'),
      'nothing',
    ),
    feedRows.element,
    feedExplanation,
    feedDetail,
    feedErrors.element,
  );

  // --- Step 3: connect ---

  const deviceRows = ui.rows([
    ['name', 'device.row.name'],
    ['model', 'device.row.model'],
    ['firmware', 'device.row.firmware'],
    ['kind', 'device.row.kind'],
  ]);
  const connectErrors = ui.errorBox();

  function showDevice(device: DeviceSummary): void {
    deviceRows.set('name', () => device.name ?? '?', 'pass');
    deviceRows.set(
      'model',
      () => device.model ?? t('value.unreadableBecause', { detail: firstLine(device.modelError) }),
      device.model ? 'pass' : 'warn',
    );
    deviceRows.set(
      'firmware',
      () => device.firmware ?? t('value.unreadableBecause', { detail: firstLine(device.firmwareError) }),
      device.firmware ? 'pass' : 'warn',
    );
    deviceRows.set('kind', () => device.kind);
    if (device.firmware === undefined && !state.flushPicked) flushChoice.set(0);
  }

  const connectButton = action(
    ui.button(
      'connect.button',
      () =>
        run(
          () =>
            diagnostics.connect().then((device) => {
              showDevice(device);
              return readStatus();
            }),
          connectErrors,
        ),
      'primary',
    ),
    'nothing',
  );

  // After the device dropped a connection attempt: most likely not in pairing mode.
  const pairingNote = ui.note('connect.pairingHint', 'warn');
  pairingNote.setAttribute('role', 'status');
  pairingNote.hidden = true;

  const stepConnect = ui.step(
    3,
    'connect.title',
    ui.note('connect.note'),
    connectButton,
    pairingNote,
    deviceRows.element,
    connectErrors.element,
  );

  // --- Step 4: status ---

  const statusRows = ui.rows([
    ['battery', 'status.row.battery'],
    ['page', 'status.row.page'],
  ]);
  const statusErrors = ui.errorBox();

  function showStatus(status: StatusReport): void {
    const battery = status.battery;
    if (battery) statusRows.set('battery', () => formatBattery(battery, getLocale()), 'pass');
    else statusRows.set('battery', () => t('value.unreadable'), 'fail');
    const slot = status.slot;
    if (slot) {
      statusRows.set(
        'page',
        () => [t('page.n', { page: slot.slot }), ' ', h('small', { class: 'muted' }, `crc ${formatCrc(slot.crc32)}`)],
        'pass',
      );
    } else {
      statusRows.set('page', () => t('value.unreadable'), 'fail');
    }
    const error = status.batteryError ?? status.slotError;
    if (error !== undefined) statusErrors.show(error);
  }

  function readStatus(): Promise<void> {
    return diagnostics.readStatus().then(showStatus);
  }

  const stepStatus = ui.step(
    4,
    'status.title',
    action(ui.button('status.button', () => run(readStatus, statusErrors)), 'session'),
    statusRows.element,
    statusErrors.element,
  );

  // --- Step 5: switch page ---

  /** Show `page` and keep step 4's "page on screen" current. */
  function switchTo(page: number, where: RefreshPlace = 'switch'): Promise<void> {
    return diagnostics.showPage(page).then(() => {
      statusRows.set('page', () => t('page.n', { page }), 'pass');
      showRefresh(where);
    });
  }

  // --- The panel refresh after switching or replacing the page on screen ---

  /** Where the refresh note shows: under the step that started the refresh. */
  type RefreshPlace = 'switch' | 'upload';
  const refreshNotes: Record<RefreshPlace, HTMLElement> = {
    switch: h('p', { class: 'note note-info', hidden: true, role: 'status' }),
    upload: h('p', { class: 'note note-info', hidden: true, role: 'status' }),
  };
  let refreshPlace: RefreshPlace | undefined;

  const renderRefresh = ui.onLocale(() => {
    for (const place of ['switch', 'upload'] as const) {
      const text = place === refreshPlace ? refreshNote(diagnostics.refreshEndsAt, Date.now()) : undefined;
      refreshNotes[place].hidden = text === undefined;
      setChildren(refreshNotes[place], text ?? '');
    }
  });

  /** The device is redrawing (not an error): say so where it started, with a countdown. */
  function showRefresh(place: RefreshPlace | undefined): void {
    refreshPlace = place;
    renderRefresh();
    keepTicking();
  }

  /** Whether a countdown is on the page (the refresh note, or the wait before reconnecting). */
  function counting(): boolean {
    const ends = diagnostics.refreshEndsAt;
    const refresh = refreshPlace !== undefined && ends !== undefined && ends > Date.now() - 1_000;
    return refresh || diagnostics.linkActivity?.type === 'waiting';
  }

  function keepTicking(): void {
    if (state.ticker !== undefined || !counting()) return;
    state.ticker = setInterval(() => {
      renderRefresh();
      sync();
      if (!counting()) {
        clearInterval(state.ticker);
        state.ticker = undefined;
      }
    }, 1_000);
  }

  const switchErrors = ui.errorBox();
  const switchNote = h('p', { class: 'muted' });
  const pageButtons = USER_SLOTS.map((page) =>
    action(
      ui.button(
        () => t('page.n', { page }),
        () => run(() => switchTo(page), switchErrors),
      ),
      'session',
    ),
  );

  const stepSwitch = ui.step(
    5,
    'switch.title',
    h('div', { class: 'grid-4' }, pageButtons),
    switchNote,
    ui.note('switch.note'),
    refreshNotes.switch,
    switchErrors.element,
  );

  // --- Step 6: upload the test card ---

  const uploadErrors = ui.errorBox();
  const onScreenWarning = ui.note('upload.onScreenWarning', 'warn');

  const pageChoice = ui.choices<number>(
    'page',
    'upload.page',
    USER_SLOTS.map((page) => ({ value: page, label: () => String(page) })),
    defaultUploadPage(undefined),
    () => {
      state.pagePicked = true;
      updatePage();
      drawPreview(testCardFrame({ page: pageChoice.value, stamp: formatStamp(new Date()) }));
    },
  );
  const modeLabels: Record<WriteModeSetting, StringKey> = {
    auto: 'upload.mode.auto',
    withoutResponse: 'upload.mode.withoutResponse',
    withResponse: 'upload.mode.withResponse',
  };
  const modeChoice = ui.choices<WriteModeSetting>(
    'mode',
    'upload.mode',
    WRITE_MODES.map((mode) => ({ value: mode, label: modeLabels[mode] })),
    'auto',
  );
  const chunkChoice = ui.choices<number>(
    'chunk',
    'upload.chunk',
    CHUNK_SIZES.map((size) => ({ value: size, label: () => String(size) })),
    CHUNK_SIZES[0],
  );
  const flushChoice = ui.choices<number>(
    'flush',
    'upload.flush',
    FLUSH_CHOICES.map((count) => ({
      value: count,
      label: count === 0 ? 'upload.flush.off' : () => t('upload.flush.every', { count }),
    })),
    FLUSH_CHOICES[0],
    () => {
      state.flushPicked = true;
    },
  );
  const resendBox = h('input', { type: 'checkbox', disabled: true });
  const resend = h('label', { class: 'check-option' }, resendBox, h('span', null, ui.text('upload.resend')));

  const preview = h('canvas', { class: 'preview', width: WIDTH, height: HEIGHT });
  ui.onLocale(() => preview.setAttribute('aria-label', t('upload.preview')))();
  function drawPreview(frame: Uint8Array): void {
    const context = preview.getContext('2d');
    if (!context) return;
    const image = context.createImageData(WIDTH, HEIGHT);
    image.data.set(previewFrame(frame).data);
    context.putImageData(image, 0, 0);
  }

  const progressFill = h('div', { class: 'progress-fill' });
  const progressBar = h('div', { class: 'progress', role: 'progressbar', 'aria-valuemin': 0, 'aria-valuemax': 100 }, progressFill);
  const progressText = h('p', { class: 'progress-text' });
  const progressBox = h('div', { class: 'progress-box', hidden: true }, progressBar, progressText);
  let lastProgressAt = 0;
  let progressNow: UploadProgress | undefined;

  const renderProgress = ui.onLocale(() => {
    const progress = progressNow;
    if (!progress) {
      setChildren(progressText, t('upload.waiting'));
      return;
    }
    const params = {
      percent: percent(progress.sent, progress.total),
      sent: formatCount(progress.sent),
      total: formatCount(progress.total),
      time: formatSeconds(progress.elapsedMs),
    };
    setChildren(progressText, t(progress.sent >= progress.total ? 'upload.progressDone' : 'upload.progress', params));
  });

  function showProgress(progress: UploadProgress | undefined): void {
    progressBox.hidden = false;
    if (progress) {
      const now = Date.now();
      if (progress.sent < progress.total && now - lastProgressAt < 100) return;
      lastProgressAt = now;
    }
    progressNow = progress;
    const share = progress ? percent(progress.sent, progress.total) : 0;
    progressFill.style.width = `${share}%`;
    progressBar.setAttribute('aria-valuenow', String(share));
    renderProgress();
  }

  const resultRows = ui.rows([
    ['outcome', 'result.row.outcome'],
    ['total', 'result.row.total'],
    ['data', 'result.row.data'],
    ['speed', 'result.row.speed'],
    ['wait', 'result.row.wait'],
    ['packets', 'result.row.packets'],
  ]);
  resultRows.element.hidden = true;

  // After an upload to a page that is not on screen: switch to it to look at the card.
  let followUpPage = USER_SLOTS[0];
  const followUp = action(
    h('button', {
      type: 'button',
      class: 'btn btn-secondary',
      hidden: true,
      onClick: () => run(() => switchTo(followUpPage, 'upload'), uploadErrors),
    }),
    'session',
  );
  const renderFollowUp = ui.onLocale(() => setChildren(followUp, t('upload.showPageN', { page: followUpPage })));

  function showUpload(report: UploadReport): void {
    resultRows.element.hidden = false;
    followUp.hidden = true;
    const outcome: Record<UploadReport['outcome'], [StringKey, Tone]> = {
      ok: ['result.ok', 'pass'],
      unchanged: ['result.unchanged', 'warn'],
      error: isAbort(report.error) ? ['result.stopped', 'warn'] : ['result.error', 'fail'],
    };
    const [key, tone] = outcome[report.outcome];
    resultRows.set('outcome', () => t(key), tone);
    resultRows.set('total', () => formatSeconds(report.totalMs));
    resultRows.set('data', () => (report.dataMs === undefined ? '—' : formatSeconds(report.dataMs)));
    resultRows.set('speed', () => (report.bytesPerSecond === undefined ? '—' : formatRate(report.bytesPerSecond)));
    resultRows.set('wait', () => (report.waitMs === undefined ? '—' : formatSeconds(report.waitMs)));
    const limited = !(report.applied.chunkSize && report.applied.writeMode);
    resultRows.set('packets', () =>
      t(limited ? 'result.packetsLimited' : 'result.packets', {
        count: formatCount(report.packets),
        size: report.chunkSize === undefined ? '?' : String(report.chunkSize),
      }),
    );
    if (report.outcome === 'error' && !isAbort(report.error)) uploadErrors.show(report.error);
    if (report.outcome === 'ok' && report.refreshing) showRefresh('upload');
    if (report.outcome === 'ok' && !report.onScreen) {
      followUpPage = report.settings.page;
      renderFollowUp();
      followUp.hidden = false;
    }
  }

  // An upload takes 25-50 s: if the screen locks meanwhile, the page is
  // suspended and the device gives up on the frame.
  const keepOnNote = ui.note('upload.keepOn', 'warn');
  keepOnNote.hidden = keepAwakeMethod() !== 'none';

  /** Keep the screen on until the returned function is called; show the note when that is not possible. */
  function holdScreen(): () => void {
    const hold = keepScreenOn();
    void hold.failed.then((why) => {
      if (why === undefined) {
        diagnostics.log.add('info', `keeping the screen on during the upload (${hold.method})`);
      } else {
        keepOnNote.hidden = false;
        diagnostics.log.add('warn', `cannot keep the screen on: ${why}`);
      }
    });
    return () => hold.release();
  }

  const sendButton = action(
    ui.button(
      'upload.send',
      () =>
        run(() => {
          const releaseScreen = holdScreen();
          const controller = new AbortController();
          state.upload = controller;
          if (refreshPlace === 'upload') showRefresh(undefined);
          showProgress(undefined);
          sync();
          return diagnostics
            .sendTestCard(
              {
                page: pageChoice.value,
                writeMode: modeChoice.value,
                chunkSize: chunkChoice.value,
                flushEvery: flushChoice.value,
                resend: resendBox.checked && diagnostics.hasPreviousCard,
              },
              { signal: controller.signal, onCard: (frame) => drawPreview(frame), onProgress: showProgress },
            )
            .then(showUpload)
            .finally(() => {
              releaseScreen();
              state.upload = undefined;
              progressBox.hidden = true;
            });
        }, uploadErrors),
      'primary',
    ),
    'session',
  );
  const stopButton = ui.button('upload.stop', () => state.upload?.abort(), 'danger');
  stopButton.hidden = true;

  function updatePage(): void {
    const shown = diagnostics.shown;
    if (!state.pagePicked && shown !== undefined) pageChoice.set(defaultUploadPage(shown));
    for (const page of USER_SLOTS) {
      const mark = pageChoice.mark(page);
      if (mark) setChildren(mark, page === shown ? ` ${t('upload.onScreen')}` : '');
    }
    onScreenWarning.hidden = shown === undefined || pageChoice.value !== shown;
    setChildren(switchNote, shown === undefined ? t('switch.shownUnknown') : t('switch.shown', { page: shown }));
    pageButtons.forEach((control, i) => control.setAttribute('aria-pressed', String(USER_SLOTS[i] === shown)));
  }
  ui.onLocale(updatePage);

  const stepUpload = ui.step(
    6,
    'upload.title',
    ui.note('upload.note'),
    pageChoice.element,
    onScreenWarning,
    modeChoice.element,
    chunkChoice.element,
    flushChoice.element,
    resend,
    h('figure', { class: 'preview-box' }, preview, h('figcaption', null, ui.text('upload.preview'))),
    keepOnNote,
    h('div', { class: 'button-row' }, sendButton, stopButton),
    progressBox,
    resultRows.element,
    refreshNotes.upload,
    followUp,
    uploadErrors.element,
  );

  // --- Step 7: disconnect ---

  const disconnectErrors = ui.errorBox();
  const stepDisconnect = ui.step(
    7,
    'disconnect.title',
    action(ui.button('disconnect.button', () => run(() => diagnostics.disconnect(), disconnectErrors)), 'session'),
    disconnectErrors.element,
  );

  // --- Log ---

  const logView = h('pre', { class: 'log', lang: 'en', 'aria-live': 'off' });
  const copyStatus = h('p', { class: 'muted', role: 'status' });
  const manualCopy = h('textarea', { class: 'manual-copy', readonly: true, hidden: true, rows: 8 });
  let copied: 'copied' | 'manual' | undefined;

  const renderCopyStatus = ui.onLocale(() => {
    setChildren(copyStatus, copied === undefined ? '' : t(copied === 'copied' ? 'log.copied' : 'log.copyManually'));
  });

  function appendLogLine(line: string): void {
    const atBottom = logView.scrollTop + logView.clientHeight >= logView.scrollHeight - 8;
    logView.appendChild(document.createTextNode(`${line}\n`));
    if (atBottom) logView.scrollTop = logView.scrollHeight;
  }

  function copyLog(): void {
    const text = buildReport(diagnostics, new Date(), `${location.origin}${location.pathname}`, getLocale());
    copyText(text).then((done) => {
      if (done) {
        manualCopy.hidden = true;
        copied = 'copied';
      } else {
        manualCopy.value = text;
        manualCopy.hidden = false;
        manualCopy.focus();
        manualCopy.select();
        copied = 'manual';
      }
      renderCopyStatus();
    });
  }

  const logCard = h(
    'section',
    { class: 'card', 'aria-labelledby': 'log-title' },
    h('h2', { id: 'log-title' }, ui.text('log.title')),
    h(
      'div',
      { class: 'button-row' },
      ui.button('log.copy', copyLog, 'primary'),
      ui.button('log.clear', () => diagnostics.log.clear()),
    ),
    copyStatus,
    manualCopy,
    logView,
  );

  // --- Wiring ---

  function setBusy(busy: boolean): void {
    state.busy = busy;
    sync();
  }

  function sync(): void {
    const session = diagnostics.session !== undefined;
    for (const { button: control, needs } of actions) {
      control.disabled = state.busy || (needs === 'session' && !session);
    }
    connectButton.disabled = state.busy || (session && diagnostics.connected);
    stopButton.hidden = state.upload === undefined;
    stopButton.disabled = state.upload === undefined;
    resendBox.disabled = state.busy || !diagnostics.hasPreviousCard;
    const { text, tone } = linkStatus(
      {
        session,
        connected: diagnostics.connected,
        name: diagnostics.device?.name,
        activity: diagnostics.linkActivity,
      },
      Date.now(),
    );
    linkState.className = `link-state tone-${tone}`;
    setChildren(linkState, text, state.busy ? h('small', { class: 'busy' }, t('link.busy')) : null);
  }
  ui.onLocale(sync);

  diagnostics.checklist.onChange(renderChecklist);
  let reconnectErrorShown: unknown;
  diagnostics.onChange(() => {
    updatePage();
    sync();
    pairingNote.hidden = !diagnostics.pairingHint;
    renderMethods();
    renderRefresh();
    keepTicking();
    // The page's own reconnect after a refresh failed: say why under step 3,
    // until a connection works again.
    const failed = diagnostics.reconnectError;
    const change = reconnectErrorChange(reconnectErrorShown, failed);
    if (change === 'show') connectErrors.show(failed);
    else if (change === 'clear') connectErrors.clear();
    reconnectErrorShown = failed;
  });
  diagnostics.log.onEntry((entry) => appendLogLine(formatLogLine(entry)));
  diagnostics.log.onClear(() => {
    setChildren(logView);
    copied = undefined;
    renderCopyStatus();
  });
  onLocaleChange((locale) => {
    ui.rerender();
    diagnostics.log.add('info', `language: ${locale}`);
  });

  setChildren(
    root,
    header,
    h(
      'main',
      null,
      linkState,
      h(
        'section',
        { class: 'card', 'aria-labelledby': 'checklist-title' },
        h('h2', { id: 'checklist-title' }, ui.text('checklist.title')),
        summary,
        checklist,
      ),
      stepBrowser,
      stepFeed,
      stepConnect,
      stepStatus,
      stepSwitch,
      stepUpload,
      stepDisconnect,
      logCard,
    ),
  );

  renderChecklist();
  updatePage();
  sync();
  drawPreview(testCardFrame({ page: pageChoice.value, stamp: formatStamp(new Date()) }));
  diagnostics.log.add('info', `diagnostics page opened (language: ${getLocale()})`);
  checkBrowser();
}

/** Copy `text` to the clipboard; false when the browser refused. */
async function copyText(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // Fall back to a selected text area below.
  }
  const area = h('textarea', { class: 'copy-buffer', readonly: true });
  area.value = text;
  document.body.appendChild(area);
  area.select();
  area.setSelectionRange(0, text.length);
  let copied = false;
  try {
    copied = document.execCommand('copy');
  } catch {
    copied = false;
  }
  area.remove();
  return copied;
}
