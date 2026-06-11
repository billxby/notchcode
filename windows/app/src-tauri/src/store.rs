// Tiny persisted overlay position, so the blob reopens where you left it.
// Stored as JSON in the app config dir (%APPDATA%\<identifier>\overlay.json).

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

/// Saved placement. `docked` true ⇒ ignore x/y and start as a top notch.
#[derive(Serialize, Deserialize, Clone, Copy, Debug)]
pub struct OverlayPos {
    pub x: i32,
    pub y: i32,
    pub docked: bool,
}

fn store_path(app: &AppHandle) -> Option<PathBuf> {
    let dir = app.path().app_config_dir().ok()?;
    Some(dir.join("overlay.json"))
}

pub fn load(app: &AppHandle) -> Option<OverlayPos> {
    let path = store_path(app)?;
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

pub fn save(app: &AppHandle, pos: OverlayPos) {
    let Some(path) = store_path(app) else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string(&pos) {
        let _ = std::fs::write(path, text);
    }
}
