// Loopback HTTP server that receives Claude Code hook callbacks — the Windows
// port of the Mac `HookServer` + `HookEvent` (notchcode-plan.md §1.1, §11.3).
//
// Wire format: the installer registers a curl command per lifecycle event that
// POSTs the event JSON (Claude Code passes it on stdin) to:
//
//     http://127.0.0.1:9876/hook/<EventName>
//
// We bind loopback-only, so the server is unreachable from the network — the
// same trust boundary the Mac enforces with an explicit isLoopback filter, here
// for free via the bind address.
//
// Hand-rolled over std::net rather than pulling in axum/tokio: the surface is
// microscopic (one verb, one route prefix, sub-KB JSON bodies), and a zero-dep
// server keeps the bundle tiny — the same call the Mac app made with
// Network.framework.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::agent::Agent;
use crate::watcher::Msg;
use crate::winutil;

/// Loopback port. Must match the installer's marker (`installer::MARKER`).
pub const HOOK_PORT: u16 = 9876;

/// Per-connection read timeout — a misbehaving client must never wedge a thread.
const CONN_TIMEOUT: Duration = Duration::from_secs(2);

/// The lifecycle moment, parsed from the URL path (`/hook/PreToolUse`), not the
/// body — Claude Code doesn't put the event name inside the payload.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum HookKind {
    PreToolUse,
    PostToolUse,
    UserPromptSubmit,
    PermissionRequest,
    Stop,
}

impl HookKind {
    fn from_path_segment(s: &str) -> Option<Self> {
        match s {
            "PreToolUse" => Some(Self::PreToolUse),
            "PostToolUse" => Some(Self::PostToolUse),
            "UserPromptSubmit" => Some(Self::UserPromptSubmit),
            "PermissionRequest" => Some(Self::PermissionRequest),
            "Stop" => Some(Self::Stop),
            _ => None,
        }
    }
}

/// A normalized hook payload. Optional everywhere — Claude Code's shapes vary by
/// event and version, and a tolerant decoder is the contract (unknown keys are
/// ignored by serde). Port of the Mac `HookEvent`.
#[derive(Clone, Debug)]
pub struct HookEvent {
    pub kind: HookKind,
    /// Which agent fired this hook — from the URL path segment
    /// (/claude/hook/… vs /codex/hook/…), not the payload.
    pub agent: Agent,
    pub session_id: Option<String>,
    pub project_path: Option<String>,
    #[allow(dead_code)] // shown on the pill/panel in w0.5/w0.6.
    pub tool_name: Option<String>,
    #[allow(dead_code)] // shown on the pill/panel in w0.5/w0.6.
    pub tool_detail: Option<String>,
    #[allow(dead_code)] // drives per-session End/liveness in w0.7.
    pub claude_pid: Option<u32>,
}

impl HookEvent {
    fn decode(kind: HookKind, agent: Agent, body: &[u8], claude_pid: Option<u32>) -> Self {
        #[derive(Deserialize)]
        struct ToolInput {
            file_path: Option<String>,
            command: Option<String>,
            pattern: Option<String>,
            url: Option<String>,
        }
        #[derive(Deserialize)]
        struct Payload {
            session_id: Option<String>,
            cwd: Option<String>,
            project_dir: Option<String>,
            tool_name: Option<String>,
            tool_input: Option<ToolInput>,
        }

        let payload: Option<Payload> = serde_json::from_slice(body).ok();

        // Pick the single most informative field per tool (the Mac mapping). We
        // don't try to be exhaustive — unknown tools fall through to just the
        // tool name on the display side.
        let tool_detail = payload.as_ref().and_then(|p| {
            let name = p.tool_name.as_deref()?;
            let input = p.tool_input.as_ref()?;
            match name {
                "Edit" | "Write" | "MultiEdit" | "Read" | "NotebookEdit" => {
                    input.file_path.as_deref().map(last_component)
                }
                "Bash" => input.command.as_ref().map(|c| truncate(c, 28)),
                "Glob" | "Grep" => input.pattern.clone(),
                "WebFetch" | "WebSearch" => input.url.clone(),
                _ => None,
            }
        });

        HookEvent {
            kind,
            agent,
            session_id: payload.as_ref().and_then(|p| p.session_id.clone()),
            // Claude Code has used both keys across versions; prefer project_dir.
            project_path: payload
                .as_ref()
                .and_then(|p| p.project_dir.clone().or_else(|| p.cwd.clone())),
            tool_name: payload.as_ref().and_then(|p| p.tool_name.clone()),
            tool_detail,
            claude_pid,
        }
    }
}

/// Forward one hook to the running app, then exit. Invoked when Claude Code
/// runs us as `notchcode.exe __notch_hook <Event>` (see `installer::hook_command`
/// and `main.rs`). This replaces the Mac shim's bash one-liner: a native, shell-
/// agnostic client sidesteps the `$PPID` / `2>/dev/null` / `|| true` bashisms
/// that silently fail under cmd.exe — the §11.3 "top open risk."
///
/// Contract mirrors the old curl call: read the event JSON from stdin, POST it
/// to `http://127.0.0.1:9876/hook/<Event>` with a 1s budget, and *never* fail
/// loudly — a down or unreachable app must never block or error Claude Code.
pub fn forward(agent: Agent, event: &str) {
    // Validate the event name against the server's routes; an unknown segment
    // would just 404, so bail early and stay silent.
    if HookKind::from_path_segment(event).is_none() {
        return;
    }

    // Drain stdin (the hook payload the agent pipes in). Cap to stay bounded
    // against a pathological producer; hook bodies are sub-KB in practice.
    let mut body = Vec::new();
    let _ = std::io::stdin()
        .take(256 * 1024)
        .read_to_end(&mut body);

    // The owning agent PID (walked past the shell) — the per-session PID the Mac
    // shim sent via $PPID, now resolved natively against this agent's process.
    let pid = winutil::resolve_session_pid(agent.process_name());

    // One wall-clock budget for the *entire* exchange. Each of connect/write/read
    // used to carry its own independent 1s timeout, so a half-open server could
    // stack them to ~3s of latency on every hook the agent fires. A single
    // deadline caps the whole thing at ~1s no matter where it stalls.
    const BUDGET: Duration = Duration::from_secs(1);
    let deadline = Instant::now() + BUDGET;
    let remaining = || {
        deadline
            .saturating_duration_since(Instant::now())
            .max(Duration::from_millis(1))
    };

    let addr = SocketAddr::from(([127, 0, 0, 1], HOOK_PORT));
    let mut stream = match TcpStream::connect_timeout(&addr, BUDGET) {
        Ok(s) => s,
        Err(_) => {
            // App isn't running — launch it and deliver this hook once it's up,
            // so a session started from a cold machine still lights the notch.
            // A deliberate exception to the 1s budget: we wait ~3s for the new
            // instance to bind. The POST that follows is fine under the (now
            // near-zero) remaining budget — the sub-KB loopback write returns
            // immediately and the response drain is best-effort/ignored.
            match connect_after_launch(&addr) {
                Some(s) => s,
                None => return,
            }
        }
    };
    let _ = stream.set_write_timeout(Some(remaining()));
    let _ = stream.set_read_timeout(Some(remaining()));

    let segment = agent.segment();
    let mut req = format!(
        "POST /{segment}/hook/{event} HTTP/1.1\r\nHost: 127.0.0.1:{HOOK_PORT}\r\n\
         Content-Length: {}\r\nConnection: close\r\n",
        body.len()
    );
    if let Some(pid) = pid {
        req.push_str(&format!("X-Notch-PID: {pid}\r\n"));
    }
    req.push_str("\r\n");

    let mut packet = req.into_bytes();
    packet.extend_from_slice(&body);
    let _ = stream.write_all(&packet);
    let _ = stream.flush();
    // Best-effort drain of the response so the server's write doesn't race a
    // RST on close; we don't care about the contents. Bounded by the remaining
    // budget, so a server that accepts then stalls can't hold us past `deadline`.
    let _ = stream.set_read_timeout(Some(remaining()));
    let mut sink = [0u8; 64];
    let _ = stream.read(&mut sink);
}

/// Launch the main app detached, then poll-connect to the loopback server until
/// it binds (~15 × 200ms ≈ 3s cap). Returns a connected stream once the freshly
/// launched (or a racing) instance is serving, or `None` if it never comes up.
///
/// Concurrency: simultaneous hooks (PreToolUse + UserPromptSubmit fire together)
/// each call this and each spawns an exe, but `tauri-plugin-single-instance`
/// keeps only one overlay — the extra processes forward-and-exit. Every
/// forwarder then connects to the one survivor and POSTs. The cost is a couple
/// of throwaway short-lived processes, never duplicate overlays.
fn connect_after_launch(addr: &SocketAddr) -> Option<TcpStream> {
    launch_detached_app();
    for _ in 0..15 {
        std::thread::sleep(Duration::from_millis(200));
        if let Ok(stream) = TcpStream::connect_timeout(addr, Duration::from_millis(200)) {
            return Some(stream);
        }
    }
    None
}

/// Spawn this very binary in normal (no-arg) app mode, fully detached so it
/// outlives this short-lived forwarder process and never flashes a console.
fn launch_detached_app() {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let mut cmd = std::process::Command::new(exe);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // DETACHED_PROCESS (0x0000_0008): not tied to this process / console.
        // CREATE_NO_WINDOW (0x0800_0000): no console window appears.
        cmd.creation_flags(0x0000_0008 | 0x0800_0000);
    }
    let _ = cmd.spawn();
}

/// Spawn the hook server. Returns immediately; serves on its own thread, one
/// short-lived thread per connection.
pub fn start(tx: Sender<Msg>) {
    std::thread::spawn(move || {
        let listener = match TcpListener::bind(("127.0.0.1", HOOK_PORT)) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("[notchcode] hook server failed to bind 127.0.0.1:{HOOK_PORT}: {e}");
                return;
            }
        };
        eprintln!("[notchcode] hook server listening on 127.0.0.1:{HOOK_PORT}");

        for stream in listener.incoming().flatten() {
            let tx = tx.clone();
            std::thread::spawn(move || handle_connection(stream, tx));
        }
    });
}

fn handle_connection(mut stream: TcpStream, tx: Sender<Msg>) {
    let _ = stream.set_read_timeout(Some(CONN_TIMEOUT));
    // Also bound writes: a local client that fills its receive window and stops
    // reading must not wedge this connection thread forever in `respond`.
    let _ = stream.set_write_timeout(Some(CONN_TIMEOUT));

    // Read until we have the full header block (or give up).
    let mut buf = Vec::new();
    let mut tmp = [0u8; 8192];
    let header_end = loop {
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break pos;
        }
        if buf.len() > 64 * 1024 {
            return respond(&mut stream, "400 Bad Request");
        }
        match stream.read(&mut tmp) {
            Ok(0) => return respond(&mut stream, "400 Bad Request"),
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(_) => return respond(&mut stream, "400 Bad Request"),
        }
    };

    let headers = String::from_utf8_lossy(&buf[..header_end]);
    let mut lines = headers.split("\r\n");

    // Request line: "POST /hook/PreToolUse HTTP/1.1"
    let request_line = lines.next().unwrap_or_default();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let path = parts.next().unwrap_or_default();

    if method != "POST" {
        return respond(&mut stream, "405 Method Not Allowed");
    }
    // Two accepted path shapes:
    //   /<agent>/hook/<Event>   — current, agent-tagged (claude|codex)
    //   /hook/<Event>           — legacy Claude installs (pre-multi-agent)
    let (agent, kind) = if let Some(rest) = path.strip_prefix("/hook/") {
        match HookKind::from_path_segment(rest) {
            Some(k) => (Agent::Claude, k),
            None => return respond(&mut stream, "404 Not Found"),
        }
    } else {
        // "/<segment>/hook/<Event>"
        let segs: Vec<&str> = path.trim_start_matches('/').splitn(3, '/').collect();
        if segs.len() == 3 && segs[1] == "hook" {
            match (
                Agent::from_segment(segs[0]),
                HookKind::from_path_segment(segs[2]),
            ) {
                (Some(a), Some(k)) => (a, k),
                _ => return respond(&mut stream, "404 Not Found"),
            }
        } else {
            return respond(&mut stream, "404 Not Found");
        }
    };

    // Pull the headers we care about. Accept the generic X-Notch-PID (current)
    // and the legacy X-Claude-PID (older Claude-only installs).
    let mut content_length = 0usize;
    let mut claude_pid = None;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            match k.trim().to_ascii_lowercase().as_str() {
                "content-length" => content_length = v.trim().parse().unwrap_or(0),
                "x-notch-pid" | "x-claude-pid" => claude_pid = v.trim().parse().ok(),
                _ => {}
            }
        }
    }

    // Body: whatever already trails the header block, plus more until we have
    // Content-Length bytes (or the socket closes / times out).
    let mut body = buf[header_end + 4..].to_vec();
    while body.len() < content_length {
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => body.extend_from_slice(&tmp[..n]),
            Err(_) => break,
        }
    }
    if content_length > 0 && body.len() > content_length {
        body.truncate(content_length);
    }

    let event = HookEvent::decode(kind, agent, &body, claude_pid);
    let _ = tx.send(Msg::Hook(event));
    respond(&mut stream, "200 OK");
}

/// Minimal HTTP response. `Connection: close` tells curl not to wait on a
/// keep-alive timeout.
fn respond(stream: &mut TcpStream, status: &str) {
    let response =
        format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn last_component(path: &str) -> String {
    path.trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(path)
        .to_string()
}

/// Trim to `max` characters, appending an ellipsis. Char-aware so multibyte
/// commands don't panic on a byte boundary.
fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let kept: String = s.chars().take(max).collect();
        format!("{kept}…")
    } else {
        s.to_string()
    }
}
