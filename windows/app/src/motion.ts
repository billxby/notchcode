// Tiny motion helpers shared by the overlay's animated transitions (pill
// idle↔active width, eased dock-snap, drag momentum). Kept framework-free and
// reduced-motion-aware so every animation has one consistent rhythm and a single
// place to honor the OS "reduce motion" setting.

/** True when the user has asked the OS to minimize motion. */
export const reduceMotion = (): boolean =>
  typeof window !== "undefined" &&
  typeof window.matchMedia === "function" &&
  window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Decelerating ease — fast out of the gate, gentle landing. */
export const easeOutCubic = (t: number): number => 1 - Math.pow(1 - t, 3);

/** Linear interpolation. */
export const lerp = (from: number, to: number, t: number): number =>
  from + (to - from) * t;

/**
 * rAF tween from 0→1 over `ms`, invoking `onFrame(easedProgress)` each frame and
 * `onDone` at the end. Returns a cancel function. Under reduced motion it jumps
 * straight to the final frame so the result still lands, just without animation.
 */
export function tween(
  ms: number,
  onFrame: (eased: number) => void,
  onDone?: () => void
): () => void {
  if (reduceMotion() || ms <= 0) {
    onFrame(1);
    onDone?.();
    return () => {};
  }
  let raf = 0;
  let start = 0;
  let cancelled = false;
  const step = (ts: number) => {
    if (cancelled) return;
    if (!start) start = ts;
    const t = Math.min(1, (ts - start) / ms);
    onFrame(easeOutCubic(t));
    if (t < 1) {
      raf = requestAnimationFrame(step);
    } else {
      onDone?.();
    }
  };
  raf = requestAnimationFrame(step);
  return () => {
    cancelled = true;
    cancelAnimationFrame(raf);
  };
}
