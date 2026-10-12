/** 頁面 / Pages: which kind of page each of the device's four pages shows, the calendar pages as they will look, and the grain of the dithering. */

import { useEffect, useState } from 'preact/hooks';
import { type CalendarKind, CALENDAR_KINDS, PAGE_KINDS, type PageKind } from '../../core/pages';
import { USER_SLOTS } from '../../core/protocol';
import { GRAIN_LEVELS } from '../../core/settings';
import { isIosBrowser } from '../../core/shortcut';
import { type StringKey, t } from '../../i18n';
import type { AppModel, ModelState } from '../model';
import { SyncCard } from './SyncView';
import { FrameCanvas } from './widgets';

const isCalendarKind = (kind: PageKind | undefined): kind is CalendarKind => CALENDAR_KINDS.includes(kind as CalendarKind);

/** A calendar page drawn for today, and the button that sends it to its page of the device. */
function CalendarPage(props: { model: AppModel; slot: number; kind: CalendarKind; busy: boolean; phoneCalendar: boolean }) {
  const { model, slot, kind, phoneCalendar } = props;
  const [indices, setIndices] = useState<Uint8Array | undefined>();
  useEffect(() => {
    let current = true;
    setIndices(undefined);
    Promise.resolve()
      .then(() => model.drawCalendar(kind))
      .then(
        (drawn) => current && setIndices(drawn),
        (error: unknown) => current && model.reportError(error),
      );
    return () => {
      current = false;
    };
  }, [model, kind, phoneCalendar]);
  return (
    <div class="calendar-page">
      <p class="small">
        {t('page.n', { page: slot })} · {t(`kind.${kind}` as StringKey)}
      </p>
      <div class="preview">{indices ? <FrameCanvas indices={indices} label={t('pages.preview', { page: slot })} /> : <div class="thumb-wait wide" />}</div>
      <button type="button" class="btn btn-secondary wide" disabled={!indices || props.busy} onClick={() => void model.sendCalendarPage(slot)}>
        {t('pages.send', { page: slot })}
      </button>
    </div>
  );
}

export function PagesView(props: { model: AppModel; state: ModelState }) {
  const { model, state } = props;
  const { pages, grain } = state.settings;
  const calendarPages = USER_SLOTS.flatMap((slot) => {
    const kind = pages[slot];
    return isCalendarKind(kind) ? [{ slot, kind }] : [];
  });
  return (
    <section aria-labelledby="pages-title">
      <h2 id="pages-title">{t('pages.title')}</h2>
      <p class="muted">{t('pages.intro')}</p>
      <ul class="plain">
        {USER_SLOTS.map((slot) => (
          <li class="field inline" key={slot}>
            <label for={`kind-${slot}`}>{t('page.n', { page: slot })}</label>
            <select id={`kind-${slot}`} value={pages[slot]} onChange={(e) => void model.setPageKind(slot, (e.currentTarget as HTMLSelectElement).value as PageKind)}>
              {PAGE_KINDS.map((kind) => (
                <option value={kind}>{t(`kind.${kind}` as StringKey)}</option>
              ))}
            </select>
          </li>
        ))}
      </ul>
      {isIosBrowser(navigator.userAgent, navigator.maxTouchPoints) && <SyncCard />}
      {calendarPages.length > 0 && !state.phoneCalendar && <p class="muted small">{t('calendar.default')}</p>}
      {calendarPages.map(({ slot, kind }) => (
        <CalendarPage key={`${slot}-${kind}`} model={model} slot={slot} kind={kind} busy={state.job !== undefined} phoneCalendar={state.phoneCalendar === true} />
      ))}
      <div class="field">
        <span>{t('grain.label')}</span>
        <div class="segmented" role="radiogroup" aria-label={t('grain.label')}>
          {GRAIN_LEVELS.map((level) => (
            <button type="button" role="radio" aria-checked={grain === level.strength} class={`seg${grain === level.strength ? ' on' : ''}`} onClick={() => void model.setGrain(level.strength)}>
              {t(`grain.${level.key}` as StringKey)}
            </button>
          ))}
        </div>
      </div>
      <p class="muted small">{t('pages.note')}</p>
    </section>
  );
}
