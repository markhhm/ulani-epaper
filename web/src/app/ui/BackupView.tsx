/** 備份 / Backup: export and import everything as one file, and the warning that iOS may clear website data. */

import { useEffect, useState } from 'preact/hooks';
import { getLocale, t } from '../../i18n';
import type { AppModel, ModelState } from '../model';
import { dateStamp, readFile, saveFile } from './files';
import { FileButton } from './widgets';

/** Whether the browser promised to keep this site's data; undefined where it cannot say. */
function usePersisted(): boolean | undefined {
  const [kept, setKept] = useState<boolean | undefined>();
  useEffect(() => {
    void navigator.storage?.persisted?.().then(setKept, () => undefined);
  }, []);
  return kept;
}

export function BackupView(props: { model: AppModel; state: ModelState; memoryOnly: boolean }) {
  const { model, state } = props;
  const [note, setNote] = useState<string | undefined>();
  const [working, setWorking] = useState(false);
  const kept = usePersisted();
  const last = state.settings.lastBackup;

  const exportFile = async () => {
    setNote(undefined);
    setWorking(true);
    try {
      const now = new Date();
      await saveFile(`paperhue-backup-${dateStamp(now)}.zip`, await model.exportBackup(), 'application/zip');
    } catch (error) {
      model.reportError(error);
    } finally {
      setWorking(false);
    }
  };

  const importFile = async (file: File) => {
    setNote(undefined);
    if (!confirm(t('backup.importConfirm'))) return;
    setWorking(true);
    try {
      setNote(t('backup.imported', { count: await model.importBackup(await readFile(file)) }));
    } catch (error) {
      model.reportError(error);
    } finally {
      setWorking(false);
    }
  };

  return (
    <section aria-labelledby="backup-title">
      <h2 id="backup-title">{t('backup.title')}</h2>
      <p class="note-box warn">{t('backup.warning')}</p>
      {props.memoryOnly && <p class="note-box warn">{t('backup.noStorage')}</p>}
      <div class="row">
        <button type="button" class="btn btn-primary" onClick={() => void exportFile()} disabled={working}>
          {t('backup.export')}
        </button>
        <FileButton label={t('backup.import')} disabled={working} onFile={(f) => void importFile(f)} />
      </div>
      <p class="muted">{last ? t('backup.last', { date: new Date(last).toLocaleString(getLocale()) }) : t('backup.never')}</p>
      {note && <p>{note}</p>}
      {kept !== undefined && <p class="muted small">{kept ? t('backup.kept') : t('backup.notKept')}</p>}
    </section>
  );
}
