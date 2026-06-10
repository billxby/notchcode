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
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::Sender;
use std::time::Duration;

use serde::Deserialize;

use crate::watcher::Msg;

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
    fn decode(kind: HookKind, body: &[u8], claude_pid: Option<u32>) -> Self {
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
    let kind = match path
        .strip_prefix("/hook/")
        .and_then(HookKind::from_path_segment)
    {
        Some(k) => k,
        None => return respond(&mut stream, "404 Not Found"),
    };

    // Pull the two headers we care about.
    let mut content_length = 0usize;
    let mut claude_pid = None;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            match k.trim().to_ascii_lowercase().as_str() {
                "content-length" => content_length = v.trim().parse().unwrap_or(0),
                "x-claude-pid" => claude_pid = v.trim().parse().ok(),
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

    let event = HookEvent::decode(kind, &body, claude_pid);
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
