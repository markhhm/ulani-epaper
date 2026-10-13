/** 我的牌卡 / My cards: the saved cards as thumbnails; one tap shows a card on the device. */

import { useEffect, useState } from 'preact/hooks';
import type { Card } from '../../core/cards';
import { cardPageSlots } from '../../core/pages';
import { t } from '../../i18n';
import type { AppModel, ModelState } from '../model';
import { readFile } from './files';
import { FileButton, FrameCanvas } from './widgets';

export function CardsView(props: { model: AppModel; state: ModelState; onEdit: (card?: Card) => void }) {
  const { model, state } = props;
  const slots = cardPageSlots(state.settings.pages);
  const busy = state.job !== undefined;
  const [selecting, setSelecting] = useState(false);
  const [picked, setPicked] = useState<string[]>([]);
  const [note, setNote] = useState<string | undefined>();

  // Draw the thumbnails one after the other (a photo takes a moment each), as they are needed. `state.cards`
  // is a new list whenever a card is added, saved or removed or a backup is restored, also when the ids stay
  // the same (an edited card has lost its frame and needs a new one).
  useEffect(() => {
    let stop = false;
    void (async () => {
      for (const card of state.cards) {
        if (stop) return;
        if (!model.drawnFrame(card)) await model.frameFor(card).catch(() => undefined);
      }
    })();
    return () => {
      stop = true;
    };
  }, [state.cards, state.settings.grain, state.ready]);

  const tap = (card: Card) => {
    if (!selecting) {
      void model.pushCard(card);
      return;
    }
    setPicked((now) => (now.includes(card.id) ? now.filter((id) => id !== card.id) : now.length < slots.length ? [...now, card.id] : now));
  };

  const upload = () => {
    const cards = picked.map((id) => state.cards.find((c) => c.id === id)).filter((c): c is Card => c !== undefined);
    setSelecting(false);
    setPicked([]);
    void model.preload(cards);
  };

  const importFile = async (file: File) => {
    setNote(undefined);
    try {
      await model.importCard(await readFile(file));
      setNote(t('backup.cardImported'));
    } catch (error) {
      model.reportError(error);
    }
  };

  return (
    <section aria-labelledby="cards-title">
      <h2 id="cards-title">{t('cards.title')}</h2>
      <div class="row">
        <button type="button" class="btn btn-primary" onClick={() => props.onEdit(undefined)} disabled={busy}>
          {t('cards.new')}
        </button>
        <FileButton label={t('cards.import')} disabled={busy} onFile={(f) => void importFile(f)} />
        {state.cards.length > 0 && !selecting && (
          <button type="button" class="btn btn-secondary" onClick={() => setSelecting(true)} disabled={busy || slots.length === 0}>
            {t('cards.preload')}
          </button>
        )}
      </div>
      {slots.length === 0 && state.cards.length > 0 && <p class="muted small">{t('cards.preloadNoPage')}</p>}
      {selecting && (
        <div class="note-box">
          <p>{t('cards.preloadHint', { max: slots.length })}</p>
          <div class="row">
            <button type="button" class="btn btn-primary" disabled={picked.length === 0 || busy} onClick={upload}>
              {t('cards.preloadGo', { count: picked.length })}
            </button>
            <button
              type="button"
              class="btn btn-secondary"
              onClick={() => {
                setSelecting(false);
                setPicked([]);
              }}
            >
              {t('cards.cancel')}
            </button>
          </div>
        </div>
      )}
      {note && <p class="muted">{note}</p>}
      {state.cards.length > 0 && state.settings.lastBackup === null && <p class="note-box warn">{t('cards.noBackup')}</p>}
      {state.ready && state.cards.length === 0 && <p class="muted">{t('cards.empty')}</p>}

      <ul class="tiles">
        {state.cards.map((card) => {
          const frame = model.drawnFrame(card);
          const page = model.pageOf(card);
          const order = picked.indexOf(card.id);
          return (
            <li class={`tile${order >= 0 ? ' picked' : ''}`} key={card.id}>
              <button type="button" class="thumb" disabled={busy && !selecting} aria-label={selecting ? t('cards.select') : t('cards.show')} onClick={() => tap(card)}>
                {frame ? <FrameCanvas frame={frame} small /> : <div class="thumb-wait" />}
                {page !== undefined && <span class="badge">{t('page.n', { page })}</span>}
                {order >= 0 && <span class="order">{order + 1}</span>}
              </button>
              <button type="button" class="btn btn-small" onClick={() => props.onEdit(card)} disabled={busy}>
                {t('cards.edit')}
              </button>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
