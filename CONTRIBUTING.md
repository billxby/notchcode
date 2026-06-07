# Contributing to Notchcode

Thanks for your interest! Contributions of all kinds are welcome — bug reports, PRs, design feedback.

## Getting started

1. Fork and clone the repo
2. Open `mac/Notchcode/Notchcode.xcodeproj` in Xcode 16+
3. `⌘R` to build and run — no external dependencies, no package resolution

Requirements: macOS 13+, Xcode 16+, and [Claude Code](https://claude.com/claude-code) installed so you have real sessions to monitor.

## Project layout

```
mac/Notchcode/Notchcode/
├── Engine/    # session state, usage/cost tracking
├── IO/        # file watcher, hook server, hook installer, JSONL parsing
├── UI/        # notch overlay, panel, settings (SwiftUI)
├── Vendored/  # notch geometry from DynamicNotchKit (MIT) — avoid editing
└── Resources/ # hook install/uninstall scripts
windows/       # Windows port (Tauri 2) — in development
```

## Ground rules

- **No third-party dependencies.** The macOS app is dependency-free by design; PRs adding Swift packages will be declined.
- **Standalone observer only.** Notchcode reads Claude Code's documented surface area (JSONL session files + `settings.json` hooks). No undocumented endpoints, no Keychain access, no coupling to other apps.
- **Never block Claude Code.** Hooks must stay fire-and-forget — a crashed or missing Notchcode can't be allowed to stall a session.
- **Everything stays local.** No analytics, telemetry, or network calls beyond loopback.

## Pull requests

- Keep PRs small and focused — one change per PR
- Test on both a notch and a non-notch Mac (or the virtual notch) if your change touches the overlay
- Match the existing code style, including the explanatory comment density

## Where help is most wanted

- **Windows port** (`windows/`, Tauri 2 + React/TS + Rust) — the biggest open area
- **Themes & customization** — designed to be community-driven from the start
- Bug reports with reproduction steps — especially around multi-monitor setups and edge-case session states

## Questions

Open an issue — happy to discuss before you invest time in a PR.
