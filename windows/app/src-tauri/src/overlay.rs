// Overlay geometry for the virtual notch.
//
// On Windows there is no hardware notch (unlike macOS, where NSScreen hands us
// exact cutout coordinates). The whole thing is a borderless, always-on-top
// window painted to *look* like a notch, parked at the top-center of the
// primary monitor. See notchcode-plan.md §11.0 / §11.2.
//
// This module is intentionally the only place that touches raw window geometry,
// so a future framework pivot (or the Win32 WS_EX_* hardening + click-through in
// a later milestone) stays isolated behind a thin seam.

use tauri::{PhysicalPosition, WebviewWindow};

/// Park the overlay flush against the top edge, horizontally centered on the
/// primary monitor, then reveal it.
///
/// Positioning is done in physical pixels so it lines up exactly with the
/// monitor's top edge. Multi-monitor placement and per-monitor DPI correctness
/// are deliberately out of scope here — that's milestone w0.2.
pub fn position_top_center(window: &WebviewWindow) {
    if let Ok(Some(monitor)) = window.primary_monitor() {
        let m_pos = monitor.position(); // top-left of the monitor (physical px)
        let m_size = monitor.size(); // monitor size (physical px)

        if let Ok(win_size) = window.outer_size() {
            let x = m_pos.x + (m_size.width as i32 - win_size.width as i32) / 2;
            let y = m_pos.y; // flush against the top edge
            let _ = window.set_position(PhysicalPosition::new(x, y));
        }
    }

    // The window is created hidden (visible: false) so it never flashes at the
    // OS default location before we move it. Reveal it now that it's placed.
    let _ = window.show();
}
