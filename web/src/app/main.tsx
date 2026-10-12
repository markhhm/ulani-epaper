/**
 * Entry of the app (index.html). For now a placeholder shell that links to
 * the diagnostics page, with the language button in the top bar.
 */

import { render } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { detectLocale, getLocale, htmlLang, type Locale, onLocaleChange, otherLocale, t, toggleLocale } from '../i18n';

/** The page's `lang` and title in `locale`. */
function applyLocale(locale: Locale): void {
  document.documentElement.lang = htmlLang(locale);
  document.title = t('title.app', undefined, locale);
}

/** Labelled with the other language ("English" while in Chinese, "中文" while in English). */
function LanguageButton() {
  return (
    <button type="button" class="lang-toggle" title={t('language.otherTitle')} onClick={() => toggleLocale()}>
      <span lang={htmlLang(otherLocale(getLocale()))}>{t('language.other')}</span>
    </button>
  );
}

function App() {
  const [, setLocale] = useState<Locale>(getLocale());
  useEffect(() => onLocaleChange(setLocale), []);
  return (
    <main class="shell">
      <header class="topbar">
        <h1>{t('appName')}</h1>
        <LanguageButton />
      </header>
      <p class="tagline">{t('tagline')}</p>
      <p>{t('shellPlaceholder')}</p>
      <p>
        <a href="./spike.html">{t('openDiagnostics')}</a>
      </p>
    </main>
  );
}

// The saved choice of the language button, else the browser's languages.
applyLocale(detectLocale());
onLocaleChange(applyLocale);

const root = document.getElementById('app');
if (root) {
  root.textContent = '';
  render(<App />, root);
}
