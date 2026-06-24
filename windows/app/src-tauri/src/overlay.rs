// Overlay geometry + styling for the virtual notch.
//
// On Windows there is no hardware notch (unlike macOS, where NSScreen hands us
// exact cutout coordinates). The whole thing is a borderless, always-on-top
// window painted to *look* like a notch, parked at the top-center of the
// primary monitor. See notchcode-plan.md §11.0 / §11.2.
//
// This module is intentionally the only place that touches raw window geometry
// and Win32 styling, so a future framework pivot stays isolated behind a thin
// seam.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use tauri::{LogicalPosition, LogicalSize, Monitor, PhysicalPosition, WebviewWindow, WindowEvent};

/// Docked (true) = snapped flush to the top edge, rendered as the notch.
/// Floating (false) = dragged somewhere on screen, rendered as a rounded blob.
/// While floating we stop auto-recentering so the watch loop doesn't yank the
/// blob back to the top. Single-window app, so a module-level flag is enough.
static DOCKED: AtomicBool = AtomicBool::new(true);

/// Name of the monitor the notch docks to (e.g. `\\.\DISPLAY2`). `None` means
/// "the primary monitor" — the historical behavior. A single-window app, so a
/// module-level cell is enough. Persisted across runs via store::OverlayPos.
static DOCKED_MONITOR: Mutex<Option<String>> = Mutex::new(None);

pub fn is_docked() -> bool {
    DOCKED.load(Ordering::Relaxed)
}

pub fn set_docked(docked: bool) {
    DOCKED.store(docked, Ordering::Relaxed);
}

/// Set (or clear, with `None`) the monitor the notch docks to.
pub fn set_docked_monitor(name: Option<String>) {
    if let Ok(mut g) = DOCKED_MONITOR.lock() {
        *g = name;
    }
}

fn docked_monitor_name() -> Option<String> {
    DOCKED_MONITOR.lock().ok().and_then(|g| g.clone())
}

/// The monitor the notch should dock to: the connected monitor whose OS name
/// matches the chosen `DOCKED_MONITOR`, else the primary. If the chosen monitor
/// is no longer connected, clear the choice so we stop chasing a ghost and fall
/// back to primary — this is what makes a notch docked on a secondary monitor
/// stay there (the watch loop and every reposition route through here) instead
/// of being yanked back to the primary.
fn target_monitor(window: &WebviewWindow) -> Option<Monitor> {
    if let Some(name) = docked_monitor_name() {
        if let Ok(monitors) = window.available_monitors() {
            if let Some(m) = monitors
                .into_iter()
                .find(|m| m.name().map(|n| n == &name).unwrap_or(false))
            {
                return Some(m);
            }
        }
        set_docked_monitor(None); // chosen monitor unplugged → fall back
    }
    window.primary_monitor().ok().flatten()
}

/// One connected monitor, for the Display picker (tray submenu / Settings).
#[derive(Serialize, Clone)]
pub struct MonitorInfo {
    /// OS monitor name — the stable key passed back to `dock_to_monitor`.
    pub name: String,
    /// Human label, e.g. "Monitor 1 (primary) · 2560×1440".
    pub label: String,
    pub primary: bool,
    /// Whether the notch is currently docked to this monitor.
    pub current: bool,
}

/// Enumerate connected monitors for the Display picker.
pub fn list_monitors(window: &WebviewWindow) -> Vec<MonitorInfo> {
    let primary_name = window
        .primary_monitor()
        .ok()
        .flatten()
        .and_then(|m| m.name().map(|s| s.to_string()));
    let current_name = docked_monitor_name().or_else(|| primary_name.clone());
    window
        .available_monitors()
        .unwrap_or_default()
        .into_iter()
        .enumerate()
        .map(|(i, m)| {
            let name = m.name().map(|s| s.to_string()).unwrap_or_default();
            let primary = Some(&name) == primary_name.as_ref();
            let current = Some(&name) == current_name.as_ref();
            let size = m.size();
            let label = format!(
                "Monitor {}{} · {}×{}",
                i + 1,
                if primary { " (primary)" } else { "" },
                size.width,
                size.height
            );
            MonitorInfo {
                name,
                label,
                primary,
                current,
            }
        })
        .collect()
}

/// Dock the notch to a chosen monitor by OS name (the Display picker). An empty
/// name means "primary". Persisting the choice is the caller's job (it holds the
/// AppHandle).
pub fn dock_to_monitor(window: &WebviewWindow, name: &str) {
    set_docked(true);
    set_docked_monitor((!name.is_empty()).then(|| name.to_string()));
    reposition(window);
}

/// The monitor name the notch is currently docked to (for persistence).
pub fn current_monitor_name() -> Option<String> {
    docked_monitor_name()
}

/// How often the watch loop re-derives primary-monitor placement and re-asserts
/// topmost. Monitor hot-plug and resolution changes have no first-class Tauri
/// event, so we poll — cheaply, and only acting when geometry actually changed.
const WATCH_INTERVAL: Duration = Duration::from_millis(1500);

/// Resting window size (logical px). Bigger than the ~200×32 pill on purpose:
/// the window is transparent, and the extra margin is the room the pill's drop
/// shadow needs — anything wider than the margin gets clipped at the window edge
/// and the shadow reads as a hard box. The pill itself stays centered/top-flush,
/// so this only enlarges the transparent (shadow) area, not the visible pill.
const PILL_SIZE: LogicalSize<f64> = LogicalSize::new(272.0, 64.0);

/// Expanded window size when the panel first opens, before the frontend has
/// measured its sheet (`resize_sheet` then snugs the window around the real
/// content). Grows downward from the pill; the pill stays screen-centered
/// because both sizes recenter on the same axis. Sized with the same shadow
/// margin around the default 340px-wide panel card.
const PANEL_SIZE: LogicalSize<f64> = LogicalSize::new(396.0, 478.0);

/// Transparent margin the window keeps around the sheet card — just enough to
/// hold the sheet's drop shadow (--elev-3: ~32px down, ~22px sideways) and no
/// more, so the window hugs the visible card instead of eating clicks in dead
/// transparent space beside/below it. Sized a few px past the shadow's reach so
/// it's contained, not clipped into a hard box. The card sits flush at the
/// window's top edge, so all of the H margin is below it (where the shadow
/// falls); the W margin splits evenly since the card is horizontally centered.
/// Keep these in lockstep with --elev-3 in App.css.
const SHEET_MARGIN_W: f64 = 56.0;
const SHEET_MARGIN_H: f64 = 38.0;

/// One-call entry point used by the setup hook: style the window, place it,
/// reveal it, then keep it correctly placed as the display environment changes.
///
/// `restore` is the persisted position from a previous run: `Some((x, y))` in
/// logical px means start *floating* there; `None` means start docked at the
/// top. `monitor` is the persisted docked-monitor name (None = primary), set
/// before placement so a docked restore lands on the right display. Placing
/// before `show()` avoids a flash at the wrong spot.
pub fn setup_overlay(window: &WebviewWindow, restore: Option<(f64, f64)>, monitor: Option<String>) {
    apply_overlay_styles(window);
    set_docked_monitor(monitor);

    match restore {
        Some((x, y)) => {
            set_docked(false);
            let _ = window.set_position(LogicalPosition::new(x, y));
        }
        None => {
            set_docked(true);
            reposition(window);
        }
    }

    // Created hidden (`visible: false`) so it never flashes at the OS default
    // location before we move it. Reveal now that it's placed.
    let _ = window.show();

    start_watchers(window);
}

/// Park the overlay flush against the top edge, horizontally centered on the
/// primary monitor.
///
/// All math is in **physical pixels**, which is what makes this DPI-correct: on
/// a 150%-scaled panel both `monitor.size()` and `outer_size()` report their
/// larger physical dimensions, so the centering ratio holds and the pill lands
/// in the same visual spot regardless of scale factor. Mixing logical and
/// physical units here is the classic source of "off by the DPI ratio" overlay
/// bugs (§11.5 #1).
pub fn reposition(window: &WebviewWindow) {
    if let Some(monitor) = target_monitor(window) {
        let m_pos = monitor.position(); // top-left of the monitor (physical px)
        let m_size = monitor.size(); // monitor size (physical px)

        if let Ok(win_size) = window.outer_size() {
            let x = m_pos.x + (m_size.width as i32 - win_size.width as i32) / 2;
            let y = m_pos.y; // flush against the top edge
            let _ = window.set_position(PhysicalPosition::new(x, y));
        }
    }
}

/// Keep the overlay correctly placed and on top as the display environment
/// shifts under it. Two sources, because Windows surfaces these differently:
///
/// - **Scale-factor changes** (window moved to a differently-scaled monitor, or
///   the user changed display scaling) arrive as a `WindowEvent`, so we react
///   immediately and crisply. We deliberately do *not* react to `Moved` — our
///   own `reposition` would feed back into it and we'd chase our tail.
/// - **Monitor hot-plug / resolution change** have no Tauri event, so a light
///   timer re-derives primary-monitor geometry and only repositions when it
///   actually changed. The same tick re-asserts `HWND_TOPMOST`, which other
///   topmost apps and focus-stealers periodically knock us out of (§11.5 #2).
fn start_watchers(window: &WebviewWindow) {
    let on_event = window.clone();
    window.on_window_event(move |event| {
        // A scale-factor change means the physical sizes we centered against are
        // now stale; recompute.
        if let WindowEvent::ScaleFactorChanged { .. } = event {
            reposition(&on_event);
        }
    });

    let watched = window.clone();
    std::thread::spawn(move || {
        // Track the last-seen primary-monitor geometry so we only move on real
        // changes (avoids fighting the user / needless set_position churn).
        let mut last_geometry: Option<(i32, i32, u32, u32)> = None;
        // Track fullscreen state so we only show/hide on the transition.
        let mut hidden_for_fullscreen = false;
        loop {
            std::thread::sleep(WATCH_INTERVAL);

            // Geometry of the monitor we're docked to (chosen or primary), so a
            // notch parked on a secondary display re-centers there, not on the
            // primary, when its resolution changes.
            if let Some(monitor) = target_monitor(&watched) {
                let p = monitor.position();
                let s = monitor.size();
                let geometry = (p.x, p.y, s.width, s.height);

                // Only re-dock to top-center when actually docked; a floating
                // blob keeps the position the user dragged it to.
                if last_geometry != Some(geometry) {
                    last_geometry = Some(geometry);
                    if is_docked() {
                        reposition(&watched);
                    }
                }
            }

            // Hide the overlay while a fullscreen app (game/video) owns the
            // foreground — nobody wants a pill over their game (§11.2). Restore
            // when they exit. Only act on the edge.
            let fullscreen = crate::winutil::foreground_is_fullscreen();
            if fullscreen && !hidden_for_fullscreen {
                let _ = watched.hide();
                hidden_for_fullscreen = true;
            } else if !fullscreen && hidden_for_fullscreen {
                let _ = watched.show();
                hidden_for_fullscreen = false;
            }

            if !hidden_for_fullscreen {
                reassert_topmost(&watched);
            }
        }
    });
}

/// Turn the plain Tauri window into an overlay: never-focused, hidden from
/// Alt-Tab/taskbar, and pinned above all normal windows.
///
/// The window is left **interactive** (not click-through): the pill is a thing
/// you click to open the panel, and a fully click-through window can't receive
/// the click that opens it. We keep the window sized to the pill at rest
/// (`PILL_SIZE`) so the interactive area blocking the desktop behind it is tiny
/// — the same trade the macOS hardware notch makes (you can't click "through"
/// it either). A future refinement could make the *idle* pill click-through and
/// flip it interactive on hover via a low-level mouse hook.
///
/// `WS_EX_NOACTIVATE` + `WS_EX_TOOLWINDOW` aren't exposed by Tauri's API, so we
/// set them as raw extended styles; `HWND_TOPMOST` handles Z-order.
/// `NOACTIVATE` still delivers mouse clicks — it only prevents the window from
/// stealing focus from the user's editor.
#[cfg(windows)]
pub fn apply_overlay_styles(window: &WebviewWindow) {
    use windows::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowLongPtrW, GWL_EXSTYLE, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
    };

    // The HWND from Tauri is the same `windows`-crate type we call into below,
    // because Cargo.toml pins the matching version.
    let hwnd = match window.hwnd() {
        Ok(h) => h,
        Err(_) => return,
    };

    // WS_EX_NOACTIVATE -> clicking the pill never steals focus.
    // WS_EX_TOOLWINDOW -> keep it out of Alt-Tab and the taskbar.
    let extra = (WS_EX_NOACTIVATE.0 | WS_EX_TOOLWINDOW.0) as isize;

    unsafe {
        // OR our flags into whatever Tauri/tao already set, rather than clobbering.
        let current = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, current | extra);
    }

    reassert_topmost(window);
}

/// Resize between the resting pill and the expanded panel. When docked we
/// recenter on the top edge; when floating we keep the blob's top-left so the
/// panel grows down from wherever the user parked it.
///
/// We recenter against the *target* `size` rather than calling `reposition`
/// (which reads `outer_size()`): immediately after `set_size`, `outer_size()`
/// can still report the old dimensions, so centering off it would place the new,
/// wider window using the old width — yanking the pill sideways as the panel
/// opens. Centering off the size we just asked for is race-free.
pub fn set_panel_open(window: &WebviewWindow, open: bool) {
    let size = if open { PANEL_SIZE } else { PILL_SIZE };
    resize_keep_center(window, size);
}

/// Fit the window snugly around the sheet card the frontend just measured
/// (logical px), keeping the shadow margin. Called from a ResizeObserver, so
/// the window tracks the sheet as the user drags its width handle and as the
/// session list grows/shrinks — content the window doesn't need stops eating
/// clicks meant for whatever is behind it.
pub fn resize_sheet(window: &WebviewWindow, sheet_w: f64, sheet_h: f64) {
    let size = LogicalSize::new(sheet_w + SHEET_MARGIN_W, sheet_h + SHEET_MARGIN_H);
    resize_keep_center(window, size);
}

/// Resize to `size`, keeping the content's visual center fixed. Docked we
/// recenter on the top edge; floating, `set_size` anchors the top-left while
/// the content is centered in the window, so a width change slides it sideways
/// by half the delta — counter-shift the left edge to cancel that, keeping the
/// blob/sheet visually pinned where the user parked it while growing down.
fn resize_keep_center(window: &WebviewWindow, size: LogicalSize<f64>) {
    // Scale of the monitor the window is actually on — not `window.scale_factor()`,
    // whose cached value can lag the window's real monitor on a mixed-DPI
    // multi-monitor setup, throwing the floating counter-shift off by the DPI
    // ratio.
    let scale = window
        .current_monitor()
        .ok()
        .flatten()
        .map(|m| m.scale_factor())
        .or_else(|| window.scale_factor().ok())
        .unwrap_or(1.0);
    let old_w = window.outer_size().map(|s| s.width as i32).ok();
    let _ = window.set_size(size);
    if is_docked() {
        reposition_sized(window, size);
    } else if let Some(old_w) = old_w {
        let new_w = (size.width * scale).round() as i32;
        let dx = (new_w - old_w) / 2;
        if dx != 0 {
            if let Ok(pos) = window.outer_position() {
                let _ = window.set_position(PhysicalPosition::new(pos.x - dx, pos.y));
            }
        }
    }
}

/// Center a window of a *known* logical `size` flush against the top edge of the
/// primary monitor. Like `reposition`, the centering math runs in physical px
/// (logical size × scale factor) so it stays DPI-correct; unlike `reposition`,
/// it doesn't read back the live window size, so it's safe to call right after a
/// resize before the new size has settled.
fn reposition_sized(window: &WebviewWindow, size: LogicalSize<f64>) {
    if let Some(monitor) = target_monitor(window) {
        let scale = monitor.scale_factor();
        let m_pos = monitor.position();
        let m_size = monitor.size();
        let win_w = (size.width * scale).round() as i32;
        let x = m_pos.x + (m_size.width as i32 - win_w) / 2;
        let y = m_pos.y; // flush against the top edge
        let _ = window.set_position(PhysicalPosition::new(x, y));
    }
}

/// Pin the window above all non-topmost windows. `SWP_NO*` means "only touch the
/// Z-order — don't move, resize, or activate." Called once at setup and then
/// periodically by the watch loop, since other topmost/fullscreen apps will
/// knock us out of topmost over time.
#[cfg(windows)]
pub fn reassert_topmost(window: &WebviewWindow) {
    use windows::Win32::UI::WindowsAndMessaging::{
        SetWindowPos, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE,
    };

    let hwnd = match window.hwnd() {
        Ok(h) => h,
        Err(_) => return,
    };

    unsafe {
        let _ = SetWindowPos(
            hwnd,
            Some(HWND_TOPMOST),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        );
    }
}

/// No-op stubs on non-Windows targets so the shared setup hook compiles everywhere.
#[cfg(not(windows))]
pub fn apply_overlay_styles(_window: &WebviewWindow) {}

#[cfg(not(windows))]
pub fn reassert_topmost(_window: &WebviewWindow) {}
