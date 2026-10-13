/** The app shell: top bar with the language button, device status, the three sections, and the editor over them. */

import { useEffect, useState } from 'preact/hooks';
import type { Card } from '../../core/cards';
import { getLocale, htmlLang, type Locale, onLocaleChange, otherLocale, type StringKey, t, toggleLocale } from '../../i18n';
import { deviceLog } from '../device';
import { explainAppError } from '../errors';
import type { AppModel, ModelState } from '../model';
import { BackupView } from './BackupView';
import { CardEditor } from './CardEditor';
import { CardsView } from './CardsView';
import { useModel } from './hooks';
import { PagesView } from './PagesView';
import { Status } from './Status';
import { SyncBanner } from './SyncView';
import { Dialog } from './widgets';

type Tab = 'cards' | 'pages' | 'backup';
/** The sections. A photo is chosen on its own page, in Pages. */
export const TABS: readonly Tab[] = ['cards', 'pages', 'backup'];

function LanguageButton() {
  return (
    <button type="button" class="lang-toggle" title={t('language.otherTitle')} onClick={() => toggleLocale()}>
      <span lang={htmlLang(otherLocale(getLocale()))}>{t('language.other')}</span>
    </button>
  );
}

/** The device log (commands, replies, each frame and upload), to copy and send back when a page comes out wrong. */
function DeviceLog() {
  const [, setLines] = useState(0);
  useEffect(() => deviceLog.onEntry(() => setLines((n) => n + 1)), []);
  const [copied, setCopied] = useState<boolean | undefined>();
  const text = deviceLog.toText();
  const copy = () => {
    const done = navigator.clipboard?.writeText(text);
    if (!done) setCopied(false);
    else done.then(() => setCopied(true), () => setCopied(false));
  };
  return (
    <details class="device-log">
      <summary>{t('log.title')}</summary>
      <button type="button" class="btn btn-small" onClick={copy}>
        {t('log.copy')}
      </button>
      {copied !== undefined && <p class="muted small">{t(copied ? 'log.copied' : 'log.copyManually')}</p>}
      <pre class="error-detail" lang="en">
        {text}
      </pre>
    </details>
  );
}

/** What the last job did, as the notice under the device status says it. */
export function noticeText(notice: NonNullable<ModelState['notice']>): string {
  switch (notice.kind) {
    case 'show':
      return t(notice.unchanged ? 'notice.showAlready' : 'notice.show', { page: notice.slot });
    case 'preload':
      return t('notice.preload', { count: notice.count });
    case 'photo':
      return t(notice.unchanged ? 'notice.photoUnchanged' : 'notice.photo', { page: notice.slot });
    case 'calendar':
      return t(notice.unchanged ? 'notice.calendarUnchanged' : 'notice.calendar', { page: notice.slot });
    case 'card':
      if (!notice.unchanged) return t('notice.card', { page: notice.slot });
      return t(notice.redraws ? 'notice.cardSwitched' : 'notice.cardAlready', { page: notice.slot });
  }
}

export function App(props: { model: AppModel; memoryOnly: boolean }) {
  const { model } = props;
  const state = useModel(model);
  const [, setLocale] = useState<Locale>(getLocale());
  useEffect(() => onLocaleChange(setLocale), []);
  const [tab, setTab] = useState<Tab>('cards');
  const [editing, setEditing] = useState<{ card?: Card } | undefined>();
  const [dismissedNotice, setDismissedNotice] = useState<unknown>();

  const explained = state.error === undefined ? undefined : explainAppError(state.error);
  const notice = state.notice !== undefined && state.notice !== dismissedNotice ? state.notice : undefined;

  return (
    <main class="shell">
      <header class="topbar">
        <h1>{t('appName')}</h1>
        <LanguageButton />
      </header>

      <Status model={model} state={state} />
      <SyncBanner model={model} state={state} />

      {explained && (
        <div class="error" role="alert">
          <p class="error-message">{explained.message}</p>
          <pre class="error-detail" lang="en">
            {explained.detail}
          </pre>
          <button type="button" class="btn btn-small" onClick={() => model.clearError()}>
            {t('app.dismiss')}
          </button>
        </div>
      )}
      {notice && (
        <div class="notice" role="status">
          <span>{noticeText(notice)}</span>
          <button type="button" class="btn btn-small" onClick={() => setDismissedNotice(notice)}>
            {t('app.dismiss')}
          </button>
        </div>
      )}

      <nav class="tabs" role="tablist" aria-label={t('app.tabs')}>
        {TABS.map((name) => (
          <button type="button" role="tab" aria-selected={tab === name} class={`tab${tab === name ? ' on' : ''}`} onClick={() => setTab(name)}>
            {t(`app.tab.${name}` as StringKey)}
          </button>
        ))}
      </nav>

      <div role="tabpanel">
        {tab === 'cards' && <CardsView model={model} state={state} onEdit={(card) => setEditing({ card })} />}
        {tab === 'pages' && <PagesView model={model} state={state} onCards={() => setTab('cards')} />}
        {tab === 'backup' && <BackupView model={model} state={state} memoryOnly={props.memoryOnly} />}
      </div>

      <footer class="foot">
        <a href="./spike.html">{t('openDiagnostics')}</a>
        <DeviceLog />
      </footer>

      {editing && <CardEditor model={model} state={state} card={editing.card} onClose={() => setEditing(undefined)} />}

      {state.offer && (
        <Dialog title={t('offer.title')}>
          <p>{t('offer.body', { page: state.offer.slot })}</p>
          <div class="actions">
            <button type="button" class="btn btn-secondary" onClick={() => model.dismissOffer()}>
              {t('offer.no')}
            </button>
            <button type="button" class="btn btn-primary" onClick={() => void model.confirmOffer()}>
              {t('offer.yes')}
            </button>
          </div>
        </Dialog>
      )}
    </main>
  );
}
