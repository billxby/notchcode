# Auto-launch + Less-intrusive, Smoother Pill (Windows)

**Date:** 2026-06-17
**Branch:** `feat/auto-launch-smooth-pill` (stacked on `ui/windows-bold-refinement`;
PR base targets that branch to avoid `App.tsx`/`App.css` conflicts).
**Scope:** `windows/app` only. macOS untouched.

## Goal

1. **Auto-launch** — notchcode should be running whenever a Claude Code / Codex
   session starts *anywhere* (any terminal, VSCode, etc.), even if the user quit
   it.
2. **Less-intrusive pill** — minimal at rest, expanding only when a session is
   active.
3. **Smooth, professional motion** — animated expand/collapse + dock-snap, pill
   hover/press micro-interactions, and drag inertia.

## Background (verified in source)

- Detection is already terminal-agnostic: global hooks in `~/.claude/settings.json`
  / `~/.codex/hooks.json` (`installer.rs`) plus a `notify` file-watcher
  (`watcher.rs`). Works for any launch location **while the app runs**.
- Release builds already enable launch-at-login (`lib.rs`) and Settings has an
  "Open at login" toggle — the always-on half largely exists.
- Gap: if the app is **not** running, the hook forwarder hits connection-refused
  and exits silently (`hooks.rs:158`). No relaunch.

## A. Auto-launch ("Both")

### A1 — On-demand relaunch
In `hooks::forward`, when `connect_timeout` fails: spawn the current exe detached
(`DETACHED_PROCESS | CREATE_NO_WINDOW`), then poll-connect to `127.0.0.1:9876`
(~15 × 200ms, ~3s hard cap) and POST the buffered payload once the new instance's
hook server binds. Never block the agent beyond the cap; give up silently on
failure (today's behavior).

### A2 — Single-instance guard
Add `tauri-plugin-single-instance`; register first in the builder. Makes A1
race-safe (simultaneous hooks each spawning an instance → only one overlay
survives, extras exit, all forwarders POST to the survivor) and fixes the latent
double-overlay-on-double-launch bug.

### A3 — Autostart visibility
Keep the existing "Open at login" toggle; add a one-line helper note clarifying
that notchcode also relaunches automatically when a session starts. No new
setting.

## B. Less-intrusive pill

Two visible-pill sizes, OS window size unchanged (the window is transparent
shadow-room; resizing it per-state would be janky and re-center churn):
- **Idle** (`status === "idle"`): minimal pill (~110px) showing just the status
  dot.
- **Active** (working / waiting / done): the full ~200px pill with glyph + detail.

Transition: a JS `requestAnimationFrame` width tween (~200ms ease) that
re-renders the parametric `NotchShape` / `BlobShape` path each frame. Gated by
`prefers-reduced-motion` (snap instantly when reduced).

## C. Smooth motion

- **C1** Animated collapse (`sheet-out`) so closing isn't instant; eased
  ~180ms glide for the dock-snap on drag release (rAF over the existing
  `setPosition` path) instead of an instant jump.
- **C2** Pure-CSS hover/press on the resting pill (scale 1.03 hover / 0.97 press
  + shadow lift).
- **C3** Drag inertia: ease the window toward the cursor (tight lerp, stays
  responsive) with light momentum + friction on release, clamped to the monitor;
  release near the top eases into the dock.
- All gated by `prefers-reduced-motion`.

## Files

**Rust:** `Cargo.toml` + `Cargo.lock` (single-instance), `lib.rs` (register
plugin), `hooks.rs` (relaunch + poll-retry + detached spawn helper).
**TS/CSS:** `App.tsx` (idle/active width tween, drag inertia, eased snap, collapse
coordination), `NotchShape.tsx` / `BlobShape.tsx` (animated width prop already
parametric), `App.css` (hover/press, idle pill, `sheet-out`, reduced-motion),
`Settings.tsx` (autostart note).

## Verification

- TS/CSS: `npm run build` + browser harness to watch the idle→active tween,
  hover/press, and snap/inertia easing.
- Rust: `~/.cargo/bin/cargo.exe check` (and `cargo build` if it completes in
  time) to compile-verify relaunch + single-instance.
- **Ceiling (honest):** the live overlay window animation, a real hook-triggered
  relaunch, and autostart-at-login need a packaged/GUI Tauri run that can't be
  driven headlessly here. Those are compile-verified + reasoned; final live
  confirmation is the user's (`npm run tauri dev`).

## Risks

- Window-position tweening can stutter on heavy frames — mitigated by keeping the
  pill window constant and tweening only the cheap SVG width + rAF position.
- Relaunch race — mitigated by single-instance (worst case: a couple of
  throwaway short-lived processes).
- Drag-inertia feel is subjective — kept subtle, reduced-motion-gated.
