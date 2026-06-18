# Notchcode Windows UI — Bold Refinement

**Date:** 2026-06-17
**Branch:** `ui/windows-bold-refinement`
**Scope:** `windows/app` (React + Tauri) only. macOS app is explicitly untouched.

## Goal

The Windows front-end works but reads as "vibecoded" — functional UI assembled
without a cohesive visual system. Make it look deliberately designed while
**keeping the existing palette** (Claude orange `#ff9d3d`, dark surface) and
**all behavior, layout, and window-sizing logic identical**. This is a pure
visual-layer pass: lower risk, maximum perceived quality gain.

## Non-Goals (YAGNI)

- No palette / color-scheme change.
- No layout, interaction, or information-architecture restructure.
- No new features, settings, or state.
- No changes to `types.ts`, Rust (`src-tauri`), Tauri config, or window sizing.
- No macOS / SwiftUI changes whatsoever.

## The Five Problems and Fixes

1. **Emoji used as UI controls** (`⚙ ‹ ✕ ↗ ■ ✓ ⚡ ◌`) — the biggest "vibecoded"
   tell. → New `src/Icons.tsx`: a custom inline-SVG icon set (gear, chevron,
   x, terminal-jump, stop, check, bolt, ring/empty). 1.5px stroke,
   `currentColor`, sized 14–16px, crisp at the small render size. Swap into
   `App.tsx`, `Settings.tsx`, `Indicators.tsx`. The branded working animations
   (mascot / pulse / spinner dingbats) **stay** — they are intentional.

2. **Flat gray cards** (`rgba(255,255,255,0.04)` everywhere, no depth). →
   Elevation system: cards/sheet get a hairline border + inner top-highlight +
   faint gradient + refined multi-layer shadow, so surfaces read as physical
   layers dropping from the notch.

3. **Ad-hoc type & spacing** (sizes scattered 8–13px; instant state changes). →
   Design tokens in `:root`: a small type scale (size + weight + tracking +
   line-height), a spacing scale, and `font-variant-numeric: tabular-nums` on
   usage / cost / runtime numerals so digits stop jittering.

4. **No interaction feel** (only `:hover`, no transitions or `:active`). →
   Motion polish: 120–160ms transitions on interactive elements, subtle
   press-scale on round buttons, row hover-lift, slightly springy `sheet-in`.
   Row action buttons reveal on hover so the resting list is calmer
   (opacity-only; behavior unchanged).

5. **Weak hierarchy** in rows / header / brake banner / usage chip. → Tighten
   contrast and weight; restyle the usage chip and brake banner as polished
   status chips with better color treatment.

## Architecture

Class names are preserved, so the TSX diff stays minimal and the CSS carries
most of the change.

- `src/App.css` — the bulk: expanded `:root` tokens, elevation, type/spacing,
  motion, per-component refinement. Existing selectors kept.
- `src/Icons.tsx` — **new**. Exports small presentational `<Icon>` components.
- `src/App.tsx` — replace emoji glyph strings with `<Icon>`; add a className or
  two for hover-reveal. No logic changes.
- `src/Settings.tsx` — replace the gear/close/back emoji with `<Icon>`.
- `src/Indicators.tsx` — replace the `✓` / `!` text glyphs with icon equivalents
  where it improves crispness; keep the animated working glyphs.

Each unit stays single-purpose: `Icons.tsx` is pure SVG presentation with no
state; `App.css` is styling only; the TSX components keep their existing
responsibilities.

## Verification

Run the Vite dev server and capture the four views — resting pill, session
panel (with and without sessions), session detail, and settings — confirming
visually that it improved before claiming completion. No success claim without
a screenshot.

## Risk

Low. No behavioral or structural code paths change; worst case is a visual
regression caught immediately by the screenshot pass and reverted in CSS.
