/**
 * The times of the Android app's scheduled sync (the user picks them; there are none by default)
 * and what each run left in the service's log (SyncScheduler.java).
 */

import type { BackgroundResult } from '../background/sync';

/** One run of the background sync, as the service logs it. */
export interface ScheduleRun {
  /** When it ran (epoch ms). */
  at: number;
  result: BackgroundResult;
  /** The device was not found: the next try (epoch ms). */
  retryAt?: number;
  /** The device was not found for 2 hours: this time is skipped. */
  gaveUp?: boolean;
}

/** "HH:MM" times, sorted, without repeats; anything else is dropped. */
export function scheduleTimes(times: readonly string[]): string[] {
  return [...new Set(times.filter((time) => /^([01]\d|2[0-3]):[0-5]\d$/.test(time)))].sort();
}
