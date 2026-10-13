/**
 * Touch and mouse gestures as numbers: how far the fingers' middle moved and how much the distance
 * between two fingers changed since the last event. One finger is a drag (scale 1); two are a drag and
 * a pinch together. Keeps no DOM, so the editors' maths can be tested.
 */

/** One step of a gesture, in the units of the pointer positions it was given. */
export interface GestureStep {
  /** Movement of the middle of the fingers since the last step. */
  readonly dx: number;
  readonly dy: number;
  /** Change of the distance between two fingers (1 for a single finger): above 1 spreads. */
  readonly scale: number;
  /** The middle of the fingers now. */
  readonly x: number;
  readonly y: number;
}

interface Point {
  x: number;
  y: number;
}

interface Metrics {
  x: number;
  y: number;
  spread: number;
}

export class PointerTracker {
  private readonly pointers = new Map<number, Point>();

  /** Number of fingers down. */
  get count(): number {
    return this.pointers.size;
  }

  get active(): boolean {
    return this.pointers.size > 0;
  }

  private metrics(): Metrics {
    const points = [...this.pointers.values()];
    const n = points.length || 1;
    const x = points.reduce((sum, p) => sum + p.x, 0) / n;
    const y = points.reduce((sum, p) => sum + p.y, 0) / n;
    const [a, b] = points;
    return { x, y, spread: a && b ? Math.hypot(a.x - b.x, a.y - b.y) : 0 };
  }

  down(id: number, x: number, y: number): void {
    this.pointers.set(id, { x, y });
  }

  up(id: number): void {
    this.pointers.delete(id);
  }

  /** The step the move of pointer `id` makes, or undefined for a pointer that is not down. */
  move(id: number, x: number, y: number): GestureStep | undefined {
    if (!this.pointers.has(id)) return undefined;
    const before = this.metrics();
    this.pointers.set(id, { x, y });
    const after = this.metrics();
    const scale = this.pointers.size >= 2 && before.spread > 0 ? after.spread / before.spread : 1;
    return { dx: after.x - before.x, dy: after.y - before.y, scale, x: after.x, y: after.y };
  }

  /** A wheel turn (or a trackpad pinch, which browsers send as a wheel with ctrl) as a zoom around (x, y). */
  static wheel(deltaY: number, x: number, y: number): GestureStep {
    return { dx: 0, dy: 0, scale: Math.exp(-deltaY / 1000), x, y };
  }
}
