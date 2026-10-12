/** Small hooks the views share. */

import { useEffect, useState } from 'preact/hooks';
import type { AppModel, ModelState } from '../model';

/** The model's state, re-rendering the component whenever it changes. */
export function useModel(model: AppModel): ModelState {
  const [, setTick] = useState(0);
  useEffect(() => {
    const stop = model.subscribe(() => setTick((n) => n + 1));
    setTick((n) => n + 1); // the state may have changed between the render and this effect
    return stop;
  }, [model]);
  return model.state;
}

/** The current time, updated every `ms` while `active` (for countdowns). */
export function useNow(active: boolean, ms = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return undefined;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(timer);
  }, [active, ms]);
  return active ? now : Date.now();
}
