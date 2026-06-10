# Notchcode for Windows

A clean-room Windows port of Notchcode — an ambient status pill for Claude Code.
Since Windows has no hardware notch, this is a borderless, always-on-top pill
parked at the top-center of the primary monitor (see `../notchcode-plan.md` §11).

Built with **Tauri 2** (Rust core + WebView2 UI).

## Requirements

- Windows 10 (1809+) or Windows 11
- [WebView2 runtime](https://developer.microsoft.com/microsoft-edge/webview2/) —
  evergreen on Win11, bootstrapped by the installer on Win10
- For development: [Rust](https://rustup.rs/), [Node.js](https://nodejs.org/)
  (18+), and the MSVC build tools

## Develop

```powershell
cd windows/app
npm install
npm run tauri dev
```

On first run the app:

- parks the pill at top-center and starts watching `%USERPROFILE%\.claude\projects\`
- starts the hook server on `127.0.0.1:9876`
- **merges Notchcode hooks into `%USERPROFILE%\.claude\settings.json`**
  (additive, idempotent, with a `…notchcode-backup-<timestamp>` written first)

Click the pill to open the session panel; click a session to drill into its
conversation, cost, and lifecycle controls.

> Launch-at-login is only registered for packaged (release) builds, not `dev`.

## Build an installer

```powershell
cd windows/app
npm run tauri build
```

This emits an **NSIS** per-user installer under
`src-tauri/target/release/bundle/nsis/`. No admin rights required to install.

## Code signing (Azure Trusted Signing)

Per §11.4, an EV cert is **not** worth it — Microsoft removed EV's automatic
SmartScreen bypass in 2024. The recommended path is **Azure Trusted Signing**
("Artifact Signing"), ~$10/mo, cloud-based, no USB token, and available to
individual developers in Canada/USA.

This repo does **not** embed signing config (it needs your account). To sign:

1. Set up an Azure Trusted Signing account + certificate profile.
2. Install the `Azure.CodeSigning.Dlib` / `trusted-signing-cli`.
3. Point Tauri at it via a sign command, e.g. in `tauri.conf.json`:

   ```jsonc
   "bundle": {
     "windows": {
       "signCommand": "trusted-signing-cli -e <endpoint> -a <account> -c <profile> %1"
     }
   }
   ```

   (Or sign the NSIS output in CI after `tauri build`.)

### SmartScreen on first launch

Even correctly signed, a brand-new publisher/file has **no SmartScreen
reputation**, so early users will see *"Windows protected your PC."* This is
expected and decays as install volume grows. To run:

> **More info → Run anyway**

Reputation accrues per publisher-cert + per file-hash as clean downloads
accumulate.

## Uninstall

Uninstall via **Settings → Apps**. To remove the Claude Code hooks, delete the
Notchcode entries (those containing `127.0.0.1:9876`) from
`%USERPROFILE%\.claude\settings.json`, or restore one of the
`settings.json.notchcode-backup-*` files.
