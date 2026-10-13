/**
 * One scheduled sync of the Android app, run by the background page: the same model and drawing
 * as the app (AppModel.syncFromShortcut: only calendar pages, the device skips the pages it already
 * holds), with the calendar read for the occasion and dropped afterwards. The result goes back to
 * the service, which retries when the device was out of reach and keeps a short log.
 */

import type { AppModel, SyncOutcome } from '../app/model';
import type { AgendaData } from '../core/agenda';
import { FeedError, type FeedProblem } from '../core/sources';

export type BackgroundResult =
  | (SyncOutcome & { message?: string })
  /** A calendar could not be read: nothing was sent. Names the feed, never its address. */
  | { outcome: 'feedError'; feed: string; reason: FeedProblem; status?: number }
  | { outcome: 'error'; message: string };

const describe = (error: unknown): string => (error instanceof Error ? `${error.name}: ${error.message}` : String(error));

export async function backgroundSync(model: AppModel, readCalendar: () => Promise<AgendaData>): Promise<BackgroundResult> {
  try {
    await model.load();
    await model.syncFromShortcut({ calendar: await readCalendar() });
    const sync: SyncOutcome = model.state.sync ?? { outcome: 'failed', updated: [], unchanged: [] };
    return model.state.error === undefined ? sync : { ...sync, message: describe(model.state.error) };
  } catch (error) {
    if (error instanceof FeedError) {
      return { outcome: 'feedError', feed: error.feed, reason: error.reason, ...(error.status === undefined ? {} : { status: error.status }) };
    }
    return { outcome: 'error', message: describe(error) };
  }
}
