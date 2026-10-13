/** 頁面 / Pages: which kind of page each of the device's four pages shows, the calendar pages as they will look (with the photo behind each), the photo pages with their photos, and the grain of the dithering. */

import { useEffect, useState } from 'preact/hooks';
import { isNativeApp } from '../../ble/select';
import { type CalendarKind, CALENDAR_KINDS, PAGE_KINDS, type PageKind } from '../../core/pages';
import { USER_SLOTS } from '../../core/protocol';
import { GRAIN_LEVELS, type PageBackground } from '../../core/settings';
import { isIosBrowser, sendsOnlyFromShortcut } from '../../core/shortcut';
import { type StringKey, t } from '../../i18n';
import { forgetCalendar } from '../calendar';
import type { AppModel, ModelState } from '../model';
import { AndroidView } from './AndroidView';
import { BackgroundControls } from './BackgroundControls';
import { SyncCard } from './SyncView';
import { FrameCanvas } from './widgets';

const isCalendarKind = (kind: PageKind | undefined): kind is CalendarKind => CALENDAR_KINDS.includes(kind as CalendarKind);

/** A calendar page drawn for today, the photo behind it, and the button that sends it to its page of the device. */
function CalendarPage(props: {
  model: AppModel;
  slot: number;
  kind: CalendarKind;
  busy: boolean;
  phoneCalendar: boolean;
  /** The photo behind the page, if it has one. */
  background: PageBackground | undefined;
  grain: number;
  /** Counts the changes of the stored photo, so a new photo with the same crop draws again. */
  photoChanges: number;
  /** Whether the page may be sent from here (not on an iPhone before the Shortcut has run). */
  canSend: boolean;
  onPhotoChange: () => void;
}) {
  const { model, slot, kind, phoneCalendar, background } = props;
  const [indices, setIndices] = useState<Uint8Array | undefined>();
  const backgroundKey = JSON.stringify(background ?? null);
  useEffect(() => {
    let current = true;
    setIndices(undefined);
    Promise.resolve()
      .then(() => model.drawCalendar(kind, slot))
      .then(
        (drawn) => current && setIndices(drawn),
        (error: unknown) => current && model.reportError(error),
      );
    return () => {
      current = false;
    };
  }, [model, slot, kind, phoneCalendar, backgroundKey, props.grain, props.photoChanges]);
  return (
    <div class="calendar-page">
      <p class="small">
        {t('page.n', { page: slot })} · {t(`kind.${kind}` as StringKey)}
      </p>
      <div class="preview">{indices ? <FrameCanvas indices={indices} label={t('pages.preview', { page: slot })} /> : <div class="thumb-wait wide" />}</div>
      {props.canSend && (
        <button type="button" class="btn btn-secondary wide" disabled={!indices || props.busy} onClick={() => void model.sendCalendarPage(slot)}>
          {t('pages.send', { page: slot })}
        </button>
      )}
      <BackgroundControls model={model} slot={slot} stored={background} onChange={props.onPhotoChange} />
    </div>
  );
}

/** A photo page: its photo as the device will show it, the button that sends it, and the controls of the photo. */
function PhotoPage(props: {
  model: AppModel;
  slot: number;
  busy: boolean;
  /** The page's photo, if it has one. */
  background: PageBackground | undefined;
  grain: number;
  /** Counts the changes of the stored photo, so a new photo with the same crop draws again. */
  photoChanges: number;
  onPhotoChange: () => void;
}) {
  const { model, slot, background } = props;
  const [indices, setIndices] = useState<Uint8Array | undefined>();
  const backgroundKey = JSON.stringify(background ?? null);
  useEffect(() => {
    let current = true;
    setIndices(undefined);
    Promise.resolve()
      .then(() => model.drawPhotoPage(slot))
      .then(
        (drawn) => current && setIndices(drawn),
        (error: unknown) => current && model.reportError(error),
      );
    return () => {
      current = false;
    };
  }, [model, slot, backgroundKey, props.grain, props.photoChanges]);
  return (
    <div class="calendar-page">
      <p class="small">
        {t('page.n', { page: slot })} · {t('kind.photo')}
      </p>
      {background && (
        <>
          <div class="preview">{indices ? <FrameCanvas indices={indices} label={t('pages.preview', { page: slot })} /> : <div class="thumb-wait wide" />}</div>
          <button type="button" class="btn btn-secondary wide" disabled={!indices || props.busy} onClick={() => void model.sendPhotoPage(slot)}>
            {t('pages.send', { page: slot })}
          </button>
        </>
      )}
      <BackgroundControls model={model} slot={slot} stored={background} photoPage onChange={props.onPhotoChange} />
    </div>
  );
}

export function PagesView(props: { model: AppModel; state: ModelState }) {
  const { model, state } = props;
  const { pages, grain, backgrounds } = state.settings;
  const native = isNativeApp();
  const ios = isIosBrowser(navigator.userAgent, navigator.maxTouchPoints);
  /** Bumped when the Android app's calendar sources change: the pages are drawn again. */
  const [sources, setSources] = useState(0);
  const [photoChanges, setPhotoChanges] = useState(0);
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
      {ios && <SyncCard />}
      {native && (
        <AndroidView
          model={model}
          onCalendarChange={() => {
            forgetCalendar();
            setSources((n) => n + 1);
          }}
        />
      )}
      {calendarPages.length > 0 && !state.phoneCalendar && !native && <p class="muted small">{t(ios ? 'calendar.sync.preview' : 'calendar.default')}</p>}
      {USER_SLOTS.map((slot) => {
        const kind = pages[slot];
        if (kind === 'photo') {
          return (
            <PhotoPage
              key={`${slot}-${kind}`}
              model={model}
              slot={slot}
              busy={state.job !== undefined}
              background={backgrounds[slot]}
              grain={grain}
              photoChanges={photoChanges}
              onPhotoChange={() => setPhotoChanges((n) => n + 1)}
            />
          );
        }
        return (
          isCalendarKind(kind) && (
            <CalendarPage
              key={`${slot}-${kind}-${sources}`}
              model={model}
              slot={slot}
              kind={kind}
              busy={state.job !== undefined}
              phoneCalendar={state.phoneCalendar === true}
              background={backgrounds[slot]}
              grain={grain}
              photoChanges={photoChanges}
              canSend={!sendsOnlyFromShortcut(ios, state.phoneCalendar === true)}
              onPhotoChange={() => setPhotoChanges((n) => n + 1)}
            />
          )
        );
      })}
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
