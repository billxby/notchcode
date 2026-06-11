// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // Hook-forwarder fast path: Claude Code runs us as
    // `notchcode.exe __notch_hook <Event>` for each lifecycle hook. Forward the
    // piped payload to the running app's loopback server and exit — never start
    // Tauri. This must be the first thing main does so a hook is microscopic.
    let mut args = std::env::args().skip(1);
    if args.next().as_deref() == Some("__notch_hook") {
        let event = args.next().unwrap_or_default();
        app_lib::forward_hook(&event);
        return;
    }

    app_lib::run()
}
