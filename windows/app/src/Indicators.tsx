// Status glyphs for the pill, session rows, and detail header — the web port
// of the Mac NotchView's StatusIndicator family. Working renders the
// user-selected animation (spinner / pulse / mascot) in Claude orange — but
// Codex sessions never use the two Claude-branded motions (the CLI flower and
// the walking mascot); they always show the pulsing dot in Codex's accent so
// the animation reads as "this is Codex, not Claude."

import { useEffect, useState } from "react";
import type { Agent, Status, WorkingAnimation } from "./types";
import { AGENT_ACCENT } from "./types";

// ---- Working animations -----------------------------------------------------

/** The Claude Code CLI's cycling dingbat "flower" — six frames at ~80ms. */
const SPINNER_FRAMES = ["✦", "✱", "✶", "✷", "✸", "✺"];

function ClaudeSpinner() {
  const [i, setI] = useState(0);
  useEffect(() => {
    // Module-scope frames: the once-mounted interval closes over a stable array
    // (a per-render literal would be a latent stale-closure footgun) and there's
    // no per-render allocation.
    const id = setInterval(() => setI((n) => (n + 1) % SPINNER_FRAMES.length), 80);
    return () => clearInterval(id);
  }, []);
  return <span className="glyph-spinner">{SPINNER_FRAMES[i]}</span>;
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
 * The pill's leading glyph. `anim` selects the working motion. `agent` colors
 * the working animation by agent (Claude → orange, Codex → its accent) and
 * forces Codex onto the pulsing dot — the two Claude-branded motions never
 * stand in for Codex. Omit `agent` (e.g. the agent-agnostic aggregate pill) to
 * keep the Claude default. `forceColor` (brake) overrides everything with a
 * static dot so the pill reads "stop".
 */
export function StatusIndicator({
  status,
  anim,
  agent,
  forceColor,
}: {
  status: Status;
  anim: WorkingAnimation;
  agent?: Agent;
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
      // Codex always pulses in its own color; Claude uses the chosen motion.
      inner =
        agent === "codex" ? (
          <span className="glyph-pulse" style={{ color: AGENT_ACCENT.codex }}>
            ✱
          </span>
        ) : (
          <WorkingGlyph anim={anim} />
        );
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

/** Quiet color dot for non-working session rows / detail header. Sits in the
 * same fixed 16×16 slot as StatusIndicator so rows mixing dots and working
 * animations keep their columns aligned. */
export function StatusDot({ status }: { status: Status }) {
  return (
    <span className="status-slot">
      <span className={`status-dot status-${status}`} />
    </span>
  );
}
