// Win32 helpers for the w0.7 rewrites (notchcode-plan.md §11.3): foreground
// window capture + focus (the terminal jump), per-PID liveness + termination
// (session lifecycle), and foreground-fullscreen detection (hide the overlay
// over games/video).
//
// All raw Win32 lives here behind small safe functions so the rest of the code
// stays platform-agnostic; non-Windows builds get no-op stubs.

#[cfg(windows)]
mod imp {
    use windows::Win32::Foundation::{CloseHandle, HWND, RECT};
    use windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    use windows::Win32::System::Threading::{
        AttachThreadInput, GetCurrentThreadId, GetExitCodeProcess, OpenProcess, TerminateProcess,
        PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        BringWindowToTop, GetForegroundWindow, GetWindowRect, GetWindowThreadProcessId,
        IsWindowVisible, SetForegroundWindow, ShowWindow, SW_RESTORE,
    };

    const STILL_ACTIVE: u32 = 259;

    /// HWND of the window currently in the foreground, as a raw isize we can
    /// stash on a session and reuse later. `None` if there isn't one.
    pub fn foreground_window() -> Option<isize> {
        let hwnd = unsafe { GetForegroundWindow() };
        if hwnd.0.is_null() {
            None
        } else {
            Some(hwnd.0 as isize)
        }
    }

    /// Bring a previously-captured window to the foreground. Uses the
    /// AttachThreadInput dance to get around Windows' focus-stealing
    /// restrictions (the §11.3 terminal-jump caveat). Best-effort.
    pub fn focus_window(raw: isize) -> bool {
        let hwnd = HWND(raw as *mut _);
        unsafe {
            if !IsWindowVisible(hwnd).as_bool() {
                return false;
            }
            let fg = GetForegroundWindow();
            let fg_thread = GetWindowThreadProcessId(fg, None);
            let our_thread = GetCurrentThreadId();

            // Attaching our input thread to the current foreground's lets
            // SetForegroundWindow actually take effect.
            let _ = AttachThreadInput(our_thread, fg_thread, true);
            let _ = ShowWindow(hwnd, SW_RESTORE);
            let _ = BringWindowToTop(hwnd);
            let ok = SetForegroundWindow(hwnd).as_bool();
            let _ = AttachThreadInput(our_thread, fg_thread, false);
            ok
        }
    }

    /// Whether a process is still running. `OpenProcess` + `GetExitCodeProcess`
    /// == STILL_ACTIVE — the Windows analog of `kill(pid, 0)`.
    pub fn is_alive(pid: u32) -> bool {
        unsafe {
            let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
                return false; // can't open ⇒ gone (or no rights; treat as gone)
            };
            let mut code = 0u32;
            let alive = GetExitCodeProcess(handle, &mut code).is_ok() && code == STILL_ACTIVE;
            let _ = CloseHandle(handle);
            alive
        }
    }

    /// Terminate a process by PID. Less graceful than a console Ctrl-Break (no
    /// clean JSONL flush) but reliable; w0.7 uses it for "End session."
    pub fn terminate(pid: u32) {
        unsafe {
            if let Ok(handle) = OpenProcess(PROCESS_TERMINATE, false, pid) {
                let _ = TerminateProcess(handle, 1);
                let _ = CloseHandle(handle);
            }
        }
    }

    /// True if the current foreground window covers its entire monitor — a
    /// fullscreen game/video. We hide the overlay while this holds (§11.2). The
    /// desktop/shell isn't fullscreen by this measure, so the check is cheap and
    /// safe to poll.
    pub fn foreground_is_fullscreen() -> bool {
        unsafe {
            let hwnd = GetForegroundWindow();
            if hwnd.0.is_null() {
                return false;
            }

            let mut win_rect = RECT::default();
            if GetWindowRect(hwnd, &mut win_rect).is_err() {
                return false;
            }

            let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            let mut info = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            if !GetMonitorInfoW(monitor, &mut info).as_bool() {
                return false;
            }
            let m = info.rcMonitor;
            win_rect.left <= m.left
                && win_rect.top <= m.top
                && win_rect.right >= m.right
                && win_rect.bottom >= m.bottom
        }
    }
}

#[cfg(not(windows))]
mod imp {
    pub fn foreground_window() -> Option<isize> {
        None
    }
    pub fn focus_window(_raw: isize) -> bool {
        false
    }
    pub fn is_alive(_pid: u32) -> bool {
        true
    }
    pub fn terminate(_pid: u32) {}
    pub fn foreground_is_fullscreen() -> bool {
        false
    }
}

pub use imp::*;
