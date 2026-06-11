// Status glyphs for the pill, session rows, and detail header — the web port
// of the Mac NotchView's StatusIndicator family. Working renders the
// user-selected animation (spinner / pulse / mascot), all in Claude orange;
// every other state is a quiet glyph.

import { useEffect, useState } from "react";
import type { Status, WorkingAnimation } from "./types";

// ---- Working animations -----------------------------------------------------

/** The Claude Code CLI's cycling dingbat "flower" — six frames at ~80ms. */
function ClaudeSpinner() {
  const frames = ["✦", "✱", "✶", "✷", "✸", "✺"];
  const [i, setI] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setI((n) => (n + 1) % frames.length), 80);
    return () => clearInterval(id);
  }, []);
  return <span className="glyph-spinner">{frames[i]}</span>;
}

/** A single 8-point star breathing — the claude.ai logo pulse, transposed. */
function ClaudePulse() {
  return <span className="glyph-pulse">✱</span>;
}

/** The chunky pixel-art figure from the CLI banner, scuttling in place. */
function ClaudeMascot() {
  return (
    <span className="glyph-mascot" aria-hidden="true">
      <span className="mascot-body">
        <span className="mascot-eye" />
        <span className="mascot-eye" />
      </span>
      <span className="mascot-feet">
        <span className="mascot-foot a" />
        <span className="mascot-foot b" />
        <span className="mascot-foot a" />
        <span className="mascot-foot b" />
      </span>
    </span>
  );
}

function WorkingGlyph({ anim }: { anim: WorkingAnimation }) {
  switch (anim) {
    case "pulse":
      return <ClaudePulse />;
    case "mascot":
      return <ClaudeMascot />;
    case "spinner":
    default:
      return <ClaudeSpinner />;
  }
}

// ---- Status indicator -------------------------------------------------------

/**
 * The pill's leading glyph. `anim` selects the working motion. `forceColor`
 * (brake) overrides everything with a static dot so the pill reads "stop".
 */
export function StatusIndicator({
  status,
  anim,
  forceColor,
}: {
  status: Status;
  anim: WorkingAnimation;
  forceColor?: string;
}) {
  if (forceColor) {
    return (
      <span className="status-slot">
        <span className="status-dot" style={{ background: forceColor }} />
      </span>
    );
  }
  let inner;
  switch (status) {
    case "working":
      inner = <WorkingGlyph anim={anim} />;
      break;
    case "waiting":
      inner = <span className="glyph-waiting">!</span>;
      break;
    case "done":
      inner = <span className="glyph-check">✓</span>;
      break;
    case "idle":
    default:
      inner = <span className="status-dot status-idle" />;
      break;
  }
  return <span className="status-slot">{inner}</span>;
}

/** Quiet color dot for non-working session rows / detail header. */
export function StatusDot({ status }: { status: Status }) {
  return <span className={`status-dot status-${status}`} />;
}
