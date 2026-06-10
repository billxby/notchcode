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

use std::time::Duration;
use tauri::{LogicalSize, PhysicalPosition, WebviewWindow, WindowEvent};

/// How often the watch loop re-derives primary-monitor placement and re-asserts
/// topmost. Monitor hot-plug and resolution changes have no first-class Tauri
/// event, so we poll — cheaply, and only acting when geometry actually changed.
const WATCH_INTERVAL: Duration = Duration::from_millis(1500);

/// Resting window size (logical px): just big enough for the pill plus its glow.
/// Kept tight so the interactive (non-click-through) area blocking the desktop
/// behind it stays minimal.
const PILL_SIZE: LogicalSize<f64> = LogicalSize::new(212.0, 40.0);

/// Expanded window size when the panel is open. Grows downward from the pill;
/// the pill stays screen-centered because both sizes recenter on the same axis.
const PANEL_SIZE: LogicalSize<f64> = LogicalSize::new(380.0, 440.0);

/// One-call entry point used by the setup hook: style the window, place it,
/// reveal it, then keep it correctly placed as the display environment changes.
pub fn setup_overlay(window: &WebviewWindow) {
    apply_overlay_styles(window);
    reposition(window);

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
    if let Ok(Some(monitor)) = window.primary_monitor() {
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

            if let Ok(Some(monitor)) = watched.primary_monitor() {
                let p = monitor.position();
                let s = monitor.size();
                let geometry = (p.x, p.y, s.width, s.height);

                if last_geometry != Some(geometry) {
                    last_geometry = Some(geometry);
                    reposition(&watched);
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

/// Resize between the resting pill and the expanded panel, then recenter so the
/// pill stays put horizontally and the panel grows downward. Driven by the
/// frontend via the `set_panel_open` command when the user clicks the pill.
pub fn set_panel_open(window: &WebviewWindow, open: bool) {
    let size = if open { PANEL_SIZE } else { PILL_SIZE };
    let _ = window.set_size(size);
    reposition(window);
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
