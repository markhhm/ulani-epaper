/**
 * Entry of the app (index.html): opens the local storage, builds the model with the real browser
 * pieces (IndexedDB, canvas drawing, Bluetooth) and shows the app.
 */

import { render } from 'preact';
import { isNativeApp } from '../ble/select';
import { localZone } from '../core/agenda';
import { MemoryStore, type Store } from '../core/library';
import { readSyncRequest } from '../core/shortcut';
import { readCalendar } from '../core/sources';
import { detectLocale, htmlLang, type Locale, onLocaleChange, t } from '../i18n';
import { keepScreenOn } from '../keepAwake';
import './app.css';
import { appCalendarHost, loadFeeds } from './android';
import { drawCalendar, setCalendarSource } from './calendar';
import { connectDevice, reconnectDevice } from './device';
import { ditherStored, drawCard } from './draw';
import { askToKeepData, openIdbStore } from './idbStore';
import { AppModel } from './model';
import { preparePhotoBytes } from './photoLoad';
import { App } from './ui/App';

/** The page's `lang` and title in `locale`. */
function applyLocale(locale: Locale): void {
  document.documentElement.lang = htmlLang(locale);
  document.title = t('title.app', undefined, locale);
}

async function start(): Promise<void> {
  // The saved choice of the language button, else the browser's languages.
  applyLocale(detectLocale());
  onLocaleChange(applyLocale);

  // Opened by the iPhone Shortcut (?sync=1#d=…): take the calendar data out of the address at once.
  // It is only held in memory, never saved.
  const sync = readSyncRequest(location.search, location.hash, localZone, Date.now());
  if (sync) history.replaceState(null, '', location.pathname);

  // The Android app: the phone's calendars and the iCal addresses, read natively (no CORS).
  if (isNativeApp()) setCalendarSource(() => readCalendar(appCalendarHost, loadFeeds(), localZone, Date.now()));

  let store: Store;
  let memoryOnly = false;
  try {
    store = await openIdbStore();
    void askToKeepData();
  } catch {
    // Private mode or blocked site data: the app works until the page is closed, and says so.
    store = new MemoryStore();
    memoryOnly = true;
  }

  const model = new AppModel({
    store,
    drawCard,
    drawCalendar,
    drawPhoto: ({ photo, crop, fit, ...dithering }) => ditherStored(photo, crop, dithering, fit),
    connect: connectDevice,
    reconnect: (onLink, signal) => reconnectDevice(onLink, signal),
    preparePhoto: preparePhotoBytes,
    keepAwake: () => keepScreenOn(),
  });

  const root = document.getElementById('app');
  if (!root) return;
  root.textContent = '';
  render(<App model={model} memoryOnly={memoryOnly} />, root);
  try {
    await model.load();
  } catch (error) {
    model.reportError(error);
    return;
  }
  if (sync) await model.syncFromShortcut(sync);
}

void start();
