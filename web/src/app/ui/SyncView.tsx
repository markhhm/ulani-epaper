/** The iPhone Shortcut sync: the button that runs the Shortcut, and what the last sync did. */

import { getLocale, type Locale, t } from '../../i18n';
import { SHORTCUT_FILE, SHORTCUT_NAME, SHORTCUT_RUN_URL } from '../../core/shortcut';
import type { AppModel, ModelState, SyncOutcome } from '../model';

const pagesText = (pages: number[], locale: Locale): string =>
  pages.map((page) => t('page.n', { page }, locale)).join(locale === 'zh-TW' ? '、' : ', ');

/** What a sync did (the iPhone Shortcut's, or a scheduled one on Android). */
export function syncText(sync: SyncOutcome, locale: Locale = getLocale()): string {
  switch (sync.outcome) {
    case 'done':
    case 'failed': {
      const head = t(sync.outcome === 'done' ? 'calendar.sync.done' : 'calendar.sync.failed', undefined, locale);
      const at = sync.outcome === 'failed' && sync.page !== undefined ? [t('calendar.sync.failedAt', { page: t('page.n', { page: sync.page }, locale) }, locale)] : [];
      const updated = sync.updated.length > 0 ? [t('calendar.sync.updated', { pages: pagesText(sync.updated, locale) }, locale)] : [];
      const unchanged = sync.unchanged.length > 0 ? [t('calendar.sync.unchanged', { pages: pagesText(sync.unchanged, locale) }, locale)] : [];
      return [head, ...at, ...updated, ...unchanged].join(' ');
    }
    default:
      return t(`calendar.sync.${sync.outcome}` as const, undefined, locale);
  }
}

/** What the sync is doing or did, at the top of the app. */
export function SyncBanner(props: { model: AppModel; state: ModelState }) {
  const { model, state } = props;
  if (state.job?.kind === 'sync') {
    return (
      <div class="notice" role="status">
        <span>{t('calendar.sync.running')}</span>
      </div>
    );
  }
  if (!state.sync) return null;
  return (
    <div class="notice" role="status">
      <span>{syncText(state.sync)}</span>
      <button type="button" class="btn btn-small" onClick={() => model.dismissSync()}>
        {t('app.dismiss')}
      </button>
    </div>
  );
}

/** On an iPhone: run the Shortcut now (it opens this page again with the data), or install it. */
export function SyncCard() {
  return (
    <div class="note-box">
      <p class="small">{t('calendar.sync.intro')}</p>
      <div class="actions">
        <a class="btn btn-secondary" href={`./${SHORTCUT_FILE}`} download={`${SHORTCUT_NAME}.shortcut`}>
          {t('calendar.sync.install')}
        </a>
        <a class="btn btn-primary" href={SHORTCUT_RUN_URL}>
          {t('calendar.sync.now')}
        </a>
      </div>
    </div>
  );
}
