mod cost;
mod hooks;
mod installer;
mod overlay;
mod sessions;
mod settings;
mod store;
mod tray;
mod watcher;
mod winutil;

use std::sync::{Arc, Mutex};

use tauri::{Manager, State};
use tauri_plugin_autostart::ManagerExt;

use sessions::{SessionDetail, SessionEngine};
use watcher::SharedEngine;

/// Hook-forwarder fast path. When Claude Code invokes us as
/// `notchcode.exe __notch_hook <Event>`, we forward stdin to the already-running
/// app's loopback server and exit — Tauri never starts. Called from `main()`
/// before `run()`, so a hook never spins up a second overlay instance.
pub fn forward_hook(event: &str) {
    hooks::forward(event);
}

// ---- Hook installer commands ------------------------------------------------

#[tauri::command]
fn install_hooks() -> Result<String, String> {
    installer::install()
}

#[tauri::command]
fn hooks_installed() -> bool {
    installer::is_installed()
}

/// Strip only Notchcode's entries from settings.json (settings "Remove" button).
#[tauri::command]
fn uninstall_hooks() -> Result<String, String> {
    installer::uninstall()
}

/// Quit Notchcode (the About section's Quit button — there's no taskbar entry).
#[tauri::command]
fn quit(app: tauri::AppHandle) {
    app.exit(0);
}

// ---- Settings commands ------------------------------------------------------

/// Current user preferences (plan tier, budget, brake threshold, animation).
#[tauri::command]
fn get_settings(state: State<settings::SharedSettings>) -> settings::AppSettings {
    state.lock().map(|s| s.clone()).unwrap_or_default()
}

/// Replace + persist user preferences. The frontend sends the whole struct.
#[tauri::command]
fn set_settings(
    app: tauri::AppHandle,
    state: State<settings::SharedSettings>,
    value: settings::AppSettings,
) {
    if let Ok(mut s) = state.lock() {
        *s = value.clone();
    }
    settings::save(&app, &value);
}

// ---- Overlay commands -------------------------------------------------------

/// Expand/collapse the overlay between the resting pill and the open panel.
#[tauri::command]
fn set_panel_open(window: tauri::WebviewWindow, open: bool) {
    overlay::set_panel_open(&window, open);
}

/// Whether the overlay is currently docked (top notch) vs floating (blob).
#[tauri::command]
fn overlay_docked() -> bool {
    overlay::is_docked()
}

/// Record docked/floating from the drag gesture. The frontend has already
/// placed the window (snapping to the top-center of whichever monitor it's on),
/// so we only update the flag — re-centering here would yank a notch docked on a
/// secondary monitor back to the primary.
#[tauri::command]
fn set_docked(docked: bool) {
    overlay::set_docked(docked);
}

/// Persist the blob's position (logical px) + docked state for next launch.
#[tauri::command]
fn save_overlay_pos(app: tauri::AppHandle, x: i32, y: i32, docked: bool) {
    store::save(&app, store::OverlayPos { x, y, docked });
}

// ---- Session commands -------------------------------------------------------

/// Full drill-down detail for one session (messages, actions, cost).
#[tauri::command]
fn get_session(engine: State<SharedEngine>, id: String) -> Option<SessionDetail> {
    engine.lock().ok()?.get_session(&id)
}

/// Acknowledge the sticky done checkmark (first tap on the pill).
#[tauri::command]
fn acknowledge_done(engine: State<SharedEngine>) {
    if let Ok(mut e) = engine.lock() {
        e.acknowledge_done();
    }
}

/// End a session: terminate its Claude process and gray the row.
#[tauri::command]
fn end_session(engine: State<SharedEngine>, id: String) -> bool {
    engine.lock().map(|mut e| e.end_session(&id)).unwrap_or(false)
}

/// Remove an ended session from the panel.
#[tauri::command]
fn remove_session(engine: State<SharedEngine>, id: String) {
    if let Ok(mut e) = engine.lock() {
        e.remove_session(&id);
    }
}

/// Jump to the terminal window where a session lives (§0.5).
/// Returns whether a window was raised.
#[tauri::command]
fn focus_terminal(engine: State<SharedEngine>, id: String) -> bool {
    let hwnd = match engine.lock() {
        Ok(e) => e.terminal_hwnd(&id),
        Err(_) => None,
    };
    hwnd.map(winutil::focus_window).unwrap_or(false)
}

// ---- Autostart commands -----------------------------------------------------

/// Whether launch-at-login is currently enabled.
#[tauri::command]
fn autostart_enabled(app: tauri::AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

/// Toggle launch-at-login (writes/removes the HKCU Run entry).
#[tauri::command]
fn set_autostart(app: tauri::AppHandle, enabled: bool) -> Result<(), String> {
    let mgr = app.autolaunch();
    let res = if enabled { mgr.enable() } else { mgr.disable() };
    res.map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let engine: SharedEngine = Arc::new(Mutex::new(SessionEngine::new()));

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(engine.clone())
        .setup(move |app| {
            // Load persisted preferences into managed state (needs the handle,
            // so it happens here rather than at builder time).
            let loaded = settings::load(app.handle());
            app.manage(settings::SharedSettings::new(loaded));

            if let Some(window) = app.get_webview_window("main") {
                // Restore a floating position from last run, else dock at top.
                let restore = store::load(app.handle())
                    .filter(|p| !p.docked)
                    .map(|p| (p.x as f64, p.y as f64));
                overlay::setup_overlay(&window, restore);
            }
            installer::ensure_installed();
            tray::setup(app.handle())?;
            watcher::start(app.handle().clone(), engine.clone());

            // Enable launch-at-login for real (packaged) installs only — don't
            // register a dev binary that the user runs ad hoc. Idempotent.
            #[cfg(not(debug_assertions))]
            {
                let _ = app.autolaunch().enable();
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            install_hooks,
            hooks_installed,
            uninstall_hooks,
            quit,
            get_settings,
            set_settings,
            set_panel_open,
            get_session,
            acknowledge_done,
            end_session,
            remove_session,
            focus_terminal,
            autostart_enabled,
            set_autostart,
            overlay_docked,
            set_docked,
            save_overlay_pos
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
