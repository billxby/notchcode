mod cost;
mod hooks;
mod installer;
mod overlay;
mod sessions;
mod watcher;
mod winutil;

use std::sync::{Arc, Mutex};

use tauri::{Manager, State};
use tauri_plugin_autostart::ManagerExt;

use sessions::{SessionDetail, SessionEngine};
use watcher::SharedEngine;

// ---- Hook installer commands ------------------------------------------------

#[tauri::command]
fn install_hooks() -> Result<String, String> {
    installer::install()
}

#[tauri::command]
fn hooks_installed() -> bool {
    installer::is_installed()
}

// ---- Overlay commands -------------------------------------------------------

/// Expand/collapse the overlay between the resting pill and the open panel.
#[tauri::command]
fn set_panel_open(window: tauri::WebviewWindow, open: bool) {
    overlay::set_panel_open(&window, open);
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

/// Jump to the terminal window where a waiting session lives (§0.5).
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
            if let Some(window) = app.get_webview_window("main") {
                overlay::setup_overlay(&window);
            }
            installer::ensure_installed();
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
            set_panel_open,
            get_session,
            acknowledge_done,
            end_session,
            remove_session,
            focus_terminal,
            autostart_enabled,
            set_autostart
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
