/** The device status at the top of the app: link, battery, what is being sent, and the redraw countdown. */

import { isNativeApp } from '../../ble/select';
import { getLocale, t } from '../../i18n';
import { formatBattery, percent } from '../../spike/format';
import { linkStatus, refreshNote } from '../../spike/linkStatus';
import type { AppModel, ModelState } from '../model';
import { useNow } from './hooks';

/** Web Bluetooth is there, or the native app provides Bluetooth. */
export function bluetoothAvailable(): boolean {
  return isNativeApp() || (typeof navigator !== 'undefined' && 'bluetooth' in navigator);
}

export function Status(props: { model: AppModel; state: ModelState }) {
  const { model, state } = props;
  const { link, job } = state;
  const redrawing = state.refreshUntil !== undefined && state.refreshUntil > Date.now();
  const now = useNow(redrawing || link.activity?.type === 'waiting');
  const supported = bluetoothAvailable();
  const known = link.name !== undefined || link.connected;
  const status = linkStatus({ session: known, connected: link.connected, name: link.name, activity: link.activity }, now);
  const progress = job?.progress;
  const sending = progress && progress.total > 0;
  const note = redrawing ? refreshNote(state.refreshUntil, now) : undefined;

  return (
    <section class="status-card" aria-label={t('app.device')}>
      <div class="status-line">
        <span class={`dot dot-${status.tone}`} aria-hidden="true" />
        <span class="status-text">{status.text}</span>
        {link.battery && (
          <span class="muted small">
            {t('status.row.battery')}: {formatBattery(link.battery, getLocale())}
          </span>
        )}
        <span class="spacer" />
        {link.connected ? (
          <button type="button" class="btn btn-secondary" onClick={() => void model.disconnect()} disabled={job !== undefined}>
            {t('disconnect.button')}
          </button>
        ) : (
          <button type="button" class="btn btn-primary" onClick={() => void model.connect()} disabled={job !== undefined || !supported}>
            {t('connect.button')}
          </button>
        )}
      </div>
      {!supported && <p class="note-box warn">{t('bluetoothUnsupported')}</p>}
      {job && (
        <div class="job" role="status">
          <span>
            {job.kind === 'connect'
              ? t('job.connecting')
              : sending
                ? t('job.sending', { page: progress.slot, percent: percent(progress.sent, progress.total) })
                : t('job.preparing')}
          </span>
          {sending && <progress max={progress.total} value={progress.sent} />}
          {job.kind !== 'connect' && (
            <button type="button" class="btn btn-small" onClick={() => model.stop()}>
              {t('upload.stop')}
            </button>
          )}
        </div>
      )}
      {note && <p class="muted small">{note}</p>}
    </section>
  );
}
