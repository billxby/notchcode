# Notchcode (Windows app)

The Tauri 2 application crate for the Windows port. For build, install, signing,
and architecture notes see [`../README.md`](../README.md) and §11 of
[`../../notchcode-plan.md`](../../notchcode-plan.md).

## Layout

- `src/` — React + TypeScript UI (the pill, panel, and drill-down views)
- `src-tauri/src/` — Rust core:
  - `overlay.rs` — window geometry + Win32 overlay styling, panel resize
  - `watcher.rs` — file watcher + engine loop, emits `notch-state`
  - `sessions.rs` — session engine + JSONL parser
  - `hooks.rs` — loopback hook server (`127.0.0.1:9876`)
  - `installer.rs` — native `settings.json` hook merge
  - `cost.rs` — token → USD pricing
  - `winutil.rs` — Win32 helpers (focus, liveness, fullscreen)

## Develop

```powershell
npm install
npm run tauri dev
```
