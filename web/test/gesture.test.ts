import { describe, expect, it } from 'vitest';
import { PointerTracker } from '../src/core/gesture';

describe('pointer gestures', () => {
  it('reports how far one finger moved since the last event', () => {
    const g = new PointerTracker();
    g.down(1, 100, 100);
    expect(g.move(1, 110, 95)).toEqual({ dx: 10, dy: -5, scale: 1, x: 110, y: 95 });
    expect(g.move(1, 112, 95)).toEqual({ dx: 2, dy: 0, scale: 1, x: 112, y: 95 });
  });

  it('reports a pinch as the change of the distance and the move of the middle', () => {
    const g = new PointerTracker();
    g.down(1, 100, 100);
    g.down(2, 200, 100);
    // The second finger moves away: distance 100 -> 150, the middle from 150 to 175.
    expect(g.move(2, 250, 100)).toEqual({ dx: 25, dy: 0, scale: 1.5, x: 175, y: 100 });
    // Both move: the first closes in.
    expect(g.move(1, 150, 100)).toEqual({ dx: 25, dy: 0, scale: 100 / 150, x: 200, y: 100 });
  });

  it('does not jump when a second finger lands or one lifts', () => {
    const g = new PointerTracker();
    g.down(1, 100, 100);
    g.down(2, 300, 300); // the middle is now elsewhere, but that is not a move
    expect(g.move(2, 300, 300)).toEqual({ dx: 0, dy: 0, scale: 1, x: 200, y: 200 });
    g.up(2);
    expect(g.move(1, 100, 100)).toEqual({ dx: 0, dy: 0, scale: 1, x: 100, y: 100 });
    expect(g.move(1, 101, 100)).toMatchObject({ dx: 1, dy: 0 });
  });

  it('ignores fingers that did not go down here and tells whether any is down', () => {
    const g = new PointerTracker();
    expect(g.move(9, 1, 1)).toBeUndefined();
    expect(g.active).toBe(false);
    g.down(1, 0, 0);
    expect(g.active).toBe(true);
    expect(g.count).toBe(1);
    g.up(1);
    expect(g.active).toBe(false);
  });

  it('reports the same pinch for a wheel turn or trackpad pinch as a scale around a point', () => {
    expect(PointerTracker.wheel(-100, 10, 20)).toEqual({ dx: 0, dy: 0, scale: Math.exp(0.1), x: 10, y: 20 });
    expect(PointerTracker.wheel(100, 10, 20).scale).toBeLessThan(1);
  });
});
