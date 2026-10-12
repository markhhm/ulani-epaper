/**
 * Entry of the app (index.html): opens the local storage, builds the model with the real browser
 * pieces (IndexedDB, canvas drawing, Bluetooth) and shows the app.
 */

import { render } from 'preact';
import { MemoryStore, type Store } from '../core/library';
import { detectLocale, htmlLang, type Locale, onLocaleChange, t } from '../i18n';
import { keepScreenOn } from '../keepAwake';
import './app.css';
import { connectDevice } from './device';
import { drawCard } from './draw';
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
    connect: connectDevice,
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
  }
}

void start();
