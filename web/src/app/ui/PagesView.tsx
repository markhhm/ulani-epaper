/** 頁面 / Pages: which kind of page each of the device's four pages shows, and the grain of the dithering. */

import { PAGE_KINDS, type PageKind } from '../../core/pages';
import { USER_SLOTS } from '../../core/protocol';
import { GRAIN_LEVELS } from '../../core/settings';
import { type StringKey, t } from '../../i18n';
import type { AppModel, ModelState } from '../model';

export function PagesView(props: { model: AppModel; state: ModelState }) {
  const { model, state } = props;
  const { pages, grain } = state.settings;
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
