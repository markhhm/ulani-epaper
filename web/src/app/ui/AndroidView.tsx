/**
 * The Android app's part of 頁面 / Pages: where the calendar pages get their calendar (the phone's
 * calendars, asked for at first use, and iCal addresses), and the scheduled sync with its last runs.
 */

import { useEffect, useState } from 'preact/hooks';
import { localZone } from '../../core/agenda';
import { type ScheduleRun, scheduleTimes } from '../../core/schedule';
import { type Feed, FeedError, hostOf, normalizeUrl, probeFeed } from '../../core/sources';
import { getLocale, type Locale, t } from '../../i18n';
import { appCalendarHost, calendarAllowed, loadFeeds, Paperhue, saveFeeds, type Schedule } from '../android';
import { feedErrorText } from '../errors';
import type { AppModel } from '../model';
import { syncText } from './SyncView';

const pad = (n: number): string => String(n).padStart(2, '0');
const clock = (ms: number): string => `${pad(new Date(ms).getHours())}:${pad(new Date(ms).getMinutes())}`;

/** One line of the run log: when, and what happened (never any calendar content). */
export function runText(run: ScheduleRun, locale: Locale = getLocale()): string {
  const day = new Date(run.at);
  const { result } = run;
  let what: string;
  switch (result.outcome) {
    case 'notFound':
      what = run.retryAt === undefined ? t('calendar.schedule.gaveUp', undefined, locale) : t('calendar.schedule.retry', { time: clock(run.retryAt) }, locale);
      break;
    case 'notPaired':
      what = t('calendar.schedule.notPaired', undefined, locale);
      break;
    case 'feedError':
      what = feedErrorText(new FeedError(result.reason, result.feed, result.status), locale);
      break;
    case 'error':
      what = t('calendar.schedule.error', { detail: result.message }, locale);
      break;
    default:
      what = syncText(result, locale);
  }
  return `${day.getMonth() + 1}/${day.getDate()} ${clock(run.at)} · ${what}`;
}

const newId = (): string => Array.from(crypto.getRandomValues(new Uint8Array(4)), (b) => b.toString(16).padStart(2, '0')).join('');

function PhoneCalendars(props: { report(error: unknown): void; onChange(): void }) {
  const { report, onChange } = props;
  const [allowed, setAllowed] = useState<boolean | undefined>();
  const [refused, setRefused] = useState(false);
  useEffect(() => {
    // At first use Android asks; afterwards only the button below asks again.
    Paperhue.checkPermissions()
      .then(async ({ calendar }) => {
        const ok = calendar === 'prompt' ? await calendarAllowed() : calendar === 'granted';
        setAllowed(ok);
        if (ok && calendar === 'prompt') onChange();
      })
      .catch(report);
  }, []);
  const allow = () =>
    calendarAllowed(true).then((ok) => {
      setAllowed(ok);
      setRefused(!ok);
      if (ok) onChange();
    }, report);
  if (allowed === undefined) return null;
  return (
    <div>
      <p class="small">{t(allowed ? 'calendar.android.phoneOn' : 'calendar.android.phoneOff')}</p>
      {!allowed && (
        <button type="button" class="btn btn-secondary" onClick={() => void allow()}>
          {t('calendar.android.allow')}
        </button>
      )}
      {refused && <p class="muted small">{t('calendar.android.settings')}</p>}
    </div>
  );
}

function Feeds(props: { report(error: unknown): void; onChange(): void }) {
  const { report, onChange } = props;
  const [feeds, setFeeds] = useState<Feed[]>(loadFeeds);
  const [name, setName] = useState('');
  const [url, setUrl] = useState('');
  const [status, setStatus] = useState<string | undefined>();
  const [busy, setBusy] = useState(false);

  const keep = (next: Feed[]) => {
    saveFeeds(next);
    setFeeds(next);
    onChange();
  };
  const add = async () => {
    setBusy(true);
    setStatus(t('feed.checking'));
    try {
      const address = normalizeUrl(url);
      const feed = await probeFeed(appCalendarHost, address, localZone, Date.now());
      keep([...feeds, { id: newId(), name: name.trim() || feed.name || hostOf(address), url: address }]);
      setName('');
      setUrl('');
      setStatus(t('feed.added', { events: feed.events.length, tasks: feed.reminders.length }));
    } catch (error) {
      setStatus(error instanceof FeedError ? feedErrorText(error) : undefined);
      if (!(error instanceof FeedError)) report(error);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div>
      <h3>{t('feed.listTitle')}</h3>
      <p class="muted small">{t('feed.listIntro')}</p>
      {feeds.length === 0 && <p class="small">{t('feed.none')}</p>}
      <ul class="plain">
        {feeds.map((feed) => (
          <li class="row between" key={feed.id}>
            <span>
              {feed.name} <span class="muted small">{hostOf(feed.url)}</span>
            </span>
            <button
              type="button"
              class="btn btn-small"
              onClick={() => {
                try {
                  keep(feeds.filter((f) => f.id !== feed.id));
                } catch (error) {
                  report(error);
                }
              }}
            >
              {t('feed.remove', { name: feed.name })}
            </button>
          </li>
        ))}
      </ul>
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void add();
        }}
      >
        <label class="field">
          <span>{t('feed.name')}</span>
          <input type="text" value={name} maxLength={40} onInput={(e) => setName((e.currentTarget as HTMLInputElement).value)} />
        </label>
        <label class="field">
          <span>{t('feed.url')}</span>
          <input type="password" autocomplete="off" value={url} onInput={(e) => setUrl((e.currentTarget as HTMLInputElement).value)} />
        </label>
        <button type="submit" class="btn btn-secondary" disabled={busy || url.trim() === ''}>
          {t('feed.add')}
        </button>
      </form>
      {status && (
        <p class="small" role="status">
          {status}
        </p>
      )}
    </div>
  );
}

function ScheduledSync(props: { report(error: unknown): void }) {
  const { report } = props;
  const [schedule, setSchedule] = useState<Schedule | undefined>();
  const [time, setTime] = useState('');
  useEffect(() => {
    // Read again when the app comes back (the battery setting, or a run that happened meanwhile).
    const read = () => {
      if (document.visibilityState === 'visible') Paperhue.getSchedule().then(setSchedule, report);
    };
    read();
    document.addEventListener('visibilitychange', read);
    return () => document.removeEventListener('visibilitychange', read);
  }, []);
  if (!schedule) return null;
  const save = (times: string[]) => Paperhue.setSchedule({ times: scheduleTimes(times), locale: getLocale() }).then(setSchedule, report);
  return (
    <div>
      <h3>{t('calendar.schedule.title')}</h3>
      <p class="muted small">{t('calendar.schedule.intro')}</p>
      {schedule.times.length === 0 && <p class="small">{t('calendar.schedule.none')}</p>}
      <ul class="plain">
        {schedule.times.map((at) => (
          <li class="row between" key={at}>
            <span>{at}</span>
            <button type="button" class="btn btn-small" onClick={() => void save(schedule.times.filter((x) => x !== at))}>
              {t('calendar.schedule.remove', { time: at })}
            </button>
          </li>
        ))}
      </ul>
      <div class="row">
        <input type="time" aria-label={t('calendar.schedule.time')} value={time} onInput={(e) => setTime((e.currentTarget as HTMLInputElement).value)} />
        <button
          type="button"
          class="btn btn-secondary"
          disabled={time === ''}
          onClick={() => {
            void save([...schedule.times, time]);
            setTime('');
          }}
        >
          {t('calendar.schedule.add')}
        </button>
      </div>
      {schedule.times.length > 0 && schedule.batteryOptimized && <p class="note-box warn small">{t('calendar.schedule.battery')}</p>}
      {schedule.runs.length > 0 && (
        <>
          <p class="small">{t('calendar.schedule.log')}</p>
          <ul class="plain muted small">
            {schedule.runs.slice(0, 5).map((run) => (
              <li key={run.at}>{runText(run)}</li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}

/** The calendar settings of the Android app; `onCalendarChange` redraws the calendar pages. */
export function AndroidView(props: { model: AppModel; onCalendarChange(): void }) {
  const report = (error: unknown) => props.model.reportError(error);
  return (
    <div class="note-box">
      <h3>{t('calendar.android.title')}</h3>
      <PhoneCalendars report={report} onChange={props.onCalendarChange} />
      <Feeds report={report} onChange={props.onCalendarChange} />
      <ScheduledSync report={report} />
    </div>
  );
}
