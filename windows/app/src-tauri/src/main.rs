// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // Hook-forwarder fast path: an agent runs us as
    // `notchcode.exe __notch_hook <agent> <Event>` for each lifecycle hook
    // (legacy Claude installs omit <agent>: `__notch_hook <Event>`). Forward the
    // piped payload to the running app's loopback server and exit — never start
    // Tauri. This must be the first thing main does so a hook is microscopic.
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("__notch_hook") => {
            let first = args.next().unwrap_or_default();
            // If the first token is a known agent segment, the event follows;
            // otherwise it's a legacy install where the token IS the event (claude).
            match first.as_str() {
                "claude" | "codex" => {
                    let event = args.next().unwrap_or_default();
                    app_lib::forward_hook(&first, &event);
                }
                _ => app_lib::forward_hook("claude", &first),
            }
            return;
        }
        // Run by the NSIS pre-uninstall hook (installer.nsh) while the exe
        // still exists: strip our hook entries from the agents' configs so
        // they don't keep invoking a deleted notchcode.exe. Tauri never starts.
        Some("__notch_uninstall") => {
            app_lib::cleanup_for_uninstall();
            return;
        }
        _ => {}
    }

    app_lib::run()
}
