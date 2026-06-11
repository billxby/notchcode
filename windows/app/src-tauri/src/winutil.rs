// Win32 helpers for the w0.7 rewrites (notchcode-plan.md §11.3): foreground
// window capture + focus (the terminal jump), per-PID liveness + termination
// (session lifecycle), and foreground-fullscreen detection (hide the overlay
// over games/video).
//
// All raw Win32 lives here behind small safe functions so the rest of the code
// stays platform-agnostic; non-Windows builds get no-op stubs.

#[cfg(windows)]
mod imp {
    use windows::core::BOOL;
    use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, RECT};
    use windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows::Win32::System::Threading::{
        AttachThreadInput, GetCurrentProcessId, GetCurrentThreadId, GetExitCodeProcess,
        OpenProcess, TerminateProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        BringWindowToTop, EnumWindows, GetForegroundWindow, GetWindow, GetWindowRect,
        GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindowVisible,
        SetForegroundWindow, ShowWindow, GW_OWNER, SW_RESTORE,
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
            // Restore only when minimized: SW_RESTORE on a maximized window
            // un-maximizes it, so an unconditional call resizes the target.
            if IsIconic(hwnd).as_bool() {
                let _ = ShowWindow(hwnd, SW_RESTORE);
            }
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

    /// The PID of the `claude` (or `node`) process that owns the hook we're
    /// forwarding. Claude Code spawns the hook command through a shell, so the
    /// forwarder's *parent* is usually `cmd.exe`/`bash.exe`, not Claude. We walk
    /// the parent chain (skipping known shells) and return the first ancestor
    /// that looks like Claude Code — the Windows analog of the Mac shim's
    /// `$PPID`, but resilient to whatever shell Claude routes hooks through.
    ///
    /// Falls back to the first non-shell ancestor, then to the immediate parent,
    /// so we always forward *something* usable for per-session liveness.
    pub fn resolve_session_pid() -> Option<u32> {
        let procs = process_snapshot();

        let parent_of = |pid: u32| -> Option<(u32, String)> {
            procs
                .iter()
                .find(|(p, _, _)| *p == pid)
                .map(|(_, ppid, _)| *ppid)
                .and_then(|ppid| {
                    procs
                        .iter()
                        .find(|(p, _, _)| *p == ppid)
                        .map(|(p, _, name)| (*p, name.clone()))
                })
        };

        const SHELLS: [&str; 9] = [
            "cmd.exe",
            "powershell.exe",
            "pwsh.exe",
            "bash.exe",
            "sh.exe",
            "conhost.exe",
            "winpty.exe",
            "git.exe",
            "env.exe",
        ];

        let me = unsafe { GetCurrentProcessId() };
        let mut cur = me;
        let mut first_non_shell: Option<u32> = None;
        let mut immediate_parent: Option<u32> = None;
        for hop in 0..8 {
            let Some((pid, name)) = parent_of(cur) else {
                break;
            };
            if hop == 0 {
                immediate_parent = Some(pid);
            }
            // Claude Code ships as `claude.exe` (native) or runs under `node.exe` (npm).
            if name.contains("claude") || name == "node.exe" {
                return Some(pid);
            }
            if first_non_shell.is_none() && !SHELLS.contains(&name.as_str()) {
                first_non_shell = Some(pid);
            }
            cur = pid;
        }
        first_non_shell.or(immediate_parent)
    }

    /// (pid, ppid, lowercased exe name) for every process — one cheap snapshot.
    fn process_snapshot() -> Vec<(u32, u32, String)> {
        let mut procs: Vec<(u32, u32, String)> = Vec::new();
        let Ok(snapshot) = (unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }) else {
            return procs;
        };
        unsafe {
            let mut entry = PROCESSENTRY32W {
                dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
                ..Default::default()
            };
            if Process32FirstW(snapshot, &mut entry).is_ok() {
                loop {
                    let end = entry
                        .szExeFile
                        .iter()
                        .position(|&c| c == 0)
                        .unwrap_or(entry.szExeFile.len());
                    let name = String::from_utf16_lossy(&entry.szExeFile[..end]).to_ascii_lowercase();
                    procs.push((entry.th32ProcessID, entry.th32ParentProcessID, name));
                    if Process32NextW(snapshot, &mut entry).is_err() {
                        break;
                    }
                }
            }
            let _ = CloseHandle(snapshot);
        }
        procs
    }

    /// A visible, unowned, titled top-level window.
    struct TopWindow {
        hwnd: isize,
        pid: u32,
        title: String,
    }

    /// Every visible top-level window with a title, plus its owning PID.
    fn top_level_windows() -> Vec<TopWindow> {
        unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
            let out = unsafe { &mut *(lparam.0 as *mut Vec<TopWindow>) };
            unsafe {
                // Skip invisible windows and owned popups (dialogs, tooltips).
                if !IsWindowVisible(hwnd).as_bool() {
                    return true.into();
                }
                if GetWindow(hwnd, GW_OWNER).is_ok_and(|o| !o.0.is_null()) {
                    return true.into();
                }
                let mut buf = [0u16; 256];
                let len = GetWindowTextW(hwnd, &mut buf);
                if len <= 0 {
                    return true.into();
                }
                let mut pid = 0u32;
                GetWindowThreadProcessId(hwnd, Some(&mut pid));
                out.push(TopWindow {
                    hwnd: hwnd.0 as isize,
                    pid,
                    title: String::from_utf16_lossy(&buf[..len as usize]),
                });
            }
            true.into()
        }

        let mut windows: Vec<TopWindow> = Vec::new();
        unsafe {
            let _ = EnumWindows(Some(collect), LPARAM(&mut windows as *mut _ as isize));
        }
        windows
    }

    /// The top-level window actually hosting a session's Claude process: walk
    /// `claude_pid`'s ancestor chain (claude → shell → Windows Terminal /
    /// VS Code / …) and return a window owned by the nearest ancestor that has
    /// one. Deterministic, unlike capturing the foreground window at hook time,
    /// which records whatever the user happened to be looking at.
    ///
    /// For multi-window processes (one Code.exe serves every VS Code window),
    /// prefer a title naming the project, then the hook-captured HWND if that
    /// process owns it, then the first window.
    pub fn session_window(claude_pid: u32, project: &str, captured: Option<isize>) -> Option<isize> {
        let procs = process_snapshot();

        // Ancestors nearest-first, starting with the Claude process itself
        // (claude.exe can own its own console window).
        let mut chain = vec![claude_pid];
        let mut cur = claude_pid;
        for _ in 0..10 {
            let Some(ppid) = procs
                .iter()
                .find(|(p, _, _)| *p == cur)
                .map(|(_, pp, _)| *pp)
            else {
                break;
            };
            if ppid == 0 || chain.contains(&ppid) {
                break;
            }
            chain.push(ppid);
            cur = ppid;
        }

        let windows = top_level_windows();
        let hint = project.to_ascii_lowercase();
        for pid in chain {
            let owned: Vec<&TopWindow> = windows.iter().filter(|w| w.pid == pid).collect();
            if owned.is_empty() {
                continue;
            }
            if !hint.is_empty() {
                if let Some(w) = owned
                    .iter()
                    .find(|w| w.title.to_ascii_lowercase().contains(&hint))
                {
                    return Some(w.hwnd);
                }
            }
            if let Some(c) = captured {
                if owned.iter().any(|w| w.hwnd == c) {
                    return Some(c);
                }
            }
            return Some(owned[0].hwnd);
        }
        None
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
    pub fn resolve_session_pid() -> Option<u32> {
        None
    }
    pub fn session_window(_claude_pid: u32, _project: &str, _captured: Option<isize>) -> Option<isize> {
        None
    }
    pub fn foreground_is_fullscreen() -> bool {
        false
    }
}

pub use imp::*;
