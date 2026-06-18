// A small, self-consistent inline-SVG icon set — the visual replacement for the
// emoji glyphs (⚙ ⓘ ⚡ ◌ ↗ ✕ ■ ✓) that used to stand in for UI controls.
// Emoji render differently per-font/-OS and can't be themed; these are pure
// vector, inherit `currentColor`, and share one geometric language: a 24-unit
// viewBox, 1.8px stroke, round caps and joins. The branded working animations
// (mascot / pulse / spinner dingbats) intentionally stay as-is in Indicators.

type IconProps = {
  /** Rendered edge length in px. The notch UI uses 14–16. */
  size?: number;
  /** Extra class hook (e.g. animation wrappers in Indicators). */
  className?: string;
};

const STROKE = 1.8;

function Svg({
  size = 15,
  className,
  filled,
  children,
}: IconProps & { filled?: boolean; children: React.ReactNode }) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={filled ? "currentColor" : "none"}
      stroke={filled ? "none" : "currentColor"}
      strokeWidth={STROKE}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

export function IconGear(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z" />
      <circle cx="12" cy="12" r="3" />
    </Svg>
  );
}

export function IconChevronLeft(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="m15 18-6-6 6-6" />
    </Svg>
  );
}

export function IconX(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M18 6 6 18" />
      <path d="m6 6 12 12" />
    </Svg>
  );
}

/** Jump-to-terminal: an arrow leaving its frame (focus the waiting terminal). */
export function IconJump(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M7 17 17 7" />
      <path d="M8 7h9v9" />
    </Svg>
  );
}

/** End session — a filled stop square (media-stop convention). */
export function IconStop(p: IconProps) {
  return (
    <Svg {...p} filled>
      <rect x="6.5" y="6.5" width="11" height="11" rx="2" />
    </Svg>
  );
}

export function IconCheck(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M20 6 9 17l-5-5" />
    </Svg>
  );
}

/** Install hooks — a lightning bolt (the "wire it up" energy). */
export function IconBolt(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M13 2 4.5 13.2a.6.6 0 0 0 .48.95H11l-1 7.85 8.5-11.2a.6.6 0 0 0-.48-.95H12z" />
    </Svg>
  );
}

/** Empty / idle — a dotted ring (no active sessions). */
export function IconRing(p: IconProps) {
  return (
    <Svg {...p}>
      <circle cx="12" cy="12" r="8" strokeDasharray="1.5 3.2" />
    </Svg>
  );
}

export function IconInfo(p: IconProps) {
  return (
    <Svg {...p}>
      <circle cx="12" cy="12" r="9.2" />
      <path d="M12 11v5" />
      <path d="M12 7.6h.01" />
    </Svg>
  );
}

/** Waiting — an exclamation (agent needs input). */
export function IconBang(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M12 6v7.5" />
      <path d="M12 18h.01" />
    </Svg>
  );
}
