// Tray-icon companion — the bottom-right fallback for users who never look up
// (notchcode-plan.md §11.0, §11.7: the taskbar tray is where Windows users'
// eyes are trained; the notch metaphor borrows attention, the tray earns it).
//
// The icon is a status-colored disc generated in code (no asset pipeline, and
// it can't drift from the CSS palette by more than this one table). Left-click
// opens the panel; right-click offers Open / Settings / Quit. The watcher loop
// calls `update` whenever the aggregate status changes.

use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager};

use crate::sessions::Status;

/// Registry id, used by `update` to find the icon again.
const TRAY_ID: &str = "notchcode-tray";

/// Event the frontend listens on to switch views ("panel" | "settings").
const OPEN_VIEW_EVENT: &str = "open-view";

/// Icon bitmap edge (px). 32 scales cleanly at common tray DPIs.
const SIZE: u32 = 32;

/// Status palette — mirrors the CSS variables in App.css (--accent, --waiting,
/// --done, .status-idle).
fn color(status: Status) -> [u8; 3] {
    match status {
        Status::Idle => [0x5b, 0x5b, 0x5f],
        Status::Working => [0xff, 0x9d, 0x3d],
        Status::Waiting => [0xff, 0xb2, 0x3d],
        Status::Done => [0x4a, 0xde, 0x80],
    }
}

fn label(status: Status) -> &'static str {
    match status {
        Status::Idle => "idle",
        Status::Working => "working",
        Status::Waiting => "waiting on you",
        Status::Done => "done",
    }
}

/// A filled status-colored disc on a transparent square, with a ~1px soft edge
/// so it doesn't alias into a staircase at tray size.
fn icon(status: Status) -> Image<'static> {
    let [r, g, b] = color(status);
    let center = (SIZE as f32 - 1.0) / 2.0;
    let radius = SIZE as f32 / 2.0 - 2.0;
    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for y in 0..SIZE {
        for x in 0..SIZE {
            let d = ((x as f32 - center).powi(2) + (y as f32 - center).powi(2)).sqrt();
            let a = (radius - d + 0.5).clamp(0.0, 1.0);
            rgba.extend_from_slice(&[r, g, b, (a * 255.0) as u8]);
        }
    }
    Image::new_owned(rgba, SIZE, SIZE)
}

/// Build the tray icon + menu. Called once from the app setup hook.
pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open panel", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Notchcode", true, None::<&str>)?;
    let menu = Menu::with_items(
        app,
        &[&open, &settings, &PredefinedMenuItem::separator(app)?, &quit],
    )?;

    TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon(Status::Idle))
        .tooltip("Notchcode — idle")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => open_view(app, "panel"),
            "settings" => open_view(app, "settings"),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                open_view(tray.app_handle(), "panel");
            }
        })
        .build(app)?;
    Ok(())
}

/// Reveal the overlay (it may be hidden behind a fullscreen app) and ask the
/// frontend to switch to the requested view.
fn open_view(app: &AppHandle, view: &str) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
    }
    let _ = app.emit(OPEN_VIEW_EVENT, view);
}

/// Reflect the aggregate status in the tray. Called by the watcher loop only
/// when the status actually changed, so the icon isn't redrawn on every cost
/// tick.
pub fn update(app: &AppHandle, status: Status) {
    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        let _ = tray.set_icon(Some(icon(status)));
        let _ = tray.set_tooltip(Some(format!("Notchcode — {}", label(status))));
    }
}
