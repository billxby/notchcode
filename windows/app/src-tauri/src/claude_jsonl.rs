// Incremental parser for Claude Code's ~/.claude/projects/<slug>/<id>.jsonl —
// the Claude counterpart to codex_rollout.rs. Both produce the agent-neutral
// `sessions::ParseResult`, so the watcher → engine path is identical.
//
// Each line is one event; we extract project (cwd), conversation text, and the
// `usage` block carried on assistant messages. Incremental cursor (offsets) and
// lock/rotation handling mirror the Mac ClaudeJSONLParser.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::cost::{Model, Usage};
use crate::sessions::{open_with_retry, project_from_cwd, ParseResult, Role};

#[derive(Deserialize)]
struct WireLine {
    #[serde(rename = "type")]
    kind: Option<String>,
    cwd: Option<String>,
    message: Option<WireMessage>,
}

#[derive(Deserialize)]
struct WireMessage {
    model: Option<String>,
    usage: Option<WireUsage>,
    content: Option<WireContent>,
}

#[derive(Deserialize)]
struct WireUsage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    cache_creation_input_tokens: Option<u64>,
    cache_creation: Option<WireCacheCreation>,
}

#[derive(Deserialize)]
struct WireCacheCreation {
    ephemeral_5m_input_tokens: Option<u64>,
    ephemeral_1h_input_tokens: Option<u64>,
}

/// `message.content` is either a raw string or an array of typed blocks.
#[derive(Deserialize)]
#[serde(untagged)]
enum WireContent {
    Text(String),
    Blocks(Vec<WireBlock>),
}

#[derive(Deserialize)]
struct WireBlock {
    #[serde(rename = "type")]
    kind: Option<String>,
    text: Option<String>,
}

impl WireContent {
    fn text(&self) -> String {
        match self {
            WireContent::Text(s) => s.clone(),
            WireContent::Blocks(blocks) => blocks
                .iter()
                .filter(|b| b.kind.as_deref() == Some("text"))
                .filter_map(|b| b.text.clone())
                .collect::<Vec<_>>()
                .join("\n"),
        }
    }
}

/// Read new bytes since last call and extract project + messages + usage. The
/// incremental cursor (offsets) and lock/rotation handling match the Mac
/// `ClaudeJSONLParser.parseNew`.
pub fn parse_new(path: &Path, offsets: &mut HashMap<PathBuf, u64>) -> ParseResult {
    let mut result = ParseResult::default();

    let Some(mut file) = open_with_retry(path) else {
        return result;
    };
    let Ok(meta) = file.metadata() else {
        return result;
    };
    let len = meta.len();

    let mut start = offsets.get(path).copied().unwrap_or(0);
    if len < start {
        start = 0; // rotated/truncated
    }
    if file.seek(SeekFrom::Start(start)).is_err() {
        return result;
    }
    let mut buf = Vec::new();
    if file.read_to_end(&mut buf).is_err() {
        return result;
    }

    let Some(last_nl) = buf.iter().rposition(|&b| b == b'\n') else {
        return result;
    };
    offsets.insert(path.to_path_buf(), start + last_nl as u64 + 1);

    for line in buf[..=last_nl].split(|&b| b == b'\n') {
        if line.is_empty() {
            continue;
        }
        decode_line(line, &mut result);
    }
    result
}

fn decode_line(line: &[u8], result: &mut ParseResult) {
    let Ok(parsed) = serde_json::from_slice::<WireLine>(line) else {
        return;
    };

    if let Some(cwd) = &parsed.cwd {
        result.project = Some(project_from_cwd(cwd));
    }

    // Cost: assistant messages carry a usage block.
    if parsed.kind.as_deref() == Some("assistant") {
        if let Some(msg) = &parsed.message {
            if let Some(w) = &msg.usage {
                let cache5m = w
                    .cache_creation
                    .as_ref()
                    .and_then(|c| c.ephemeral_5m_input_tokens)
                    .or(w.cache_creation_input_tokens)
                    .unwrap_or(0);
                let cache1h = w
                    .cache_creation
                    .as_ref()
                    .and_then(|c| c.ephemeral_1h_input_tokens)
                    .unwrap_or(0);
                let usage = Usage {
                    input_tokens: w.input_tokens.unwrap_or(0),
                    output_tokens: w.output_tokens.unwrap_or(0),
                    cache_create_5m_tokens: cache5m,
                    cache_create_1h_tokens: cache1h,
                    cache_read_tokens: w.cache_read_input_tokens.unwrap_or(0),
                };
                result
                    .usages
                    .push((usage, Model::from_wire(msg.model.as_deref())));
            }
        }
    }

    // Message text: user or assistant lines with non-empty, sanitized text.
    let role = match parsed.kind.as_deref() {
        Some("user") => Some(Role::User),
        Some("assistant") => Some(Role::Assistant),
        _ => None,
    };
    if let (Some(role), Some(msg)) = (role, &parsed.message) {
        if let Some(content) = &msg.content {
            let trimmed = content.text();
            let trimmed = trimmed.trim();
            if let Some(text) = sanitize_user_content(trimmed) {
                if !text.is_empty() {
                    result.messages.push((role, text));
                }
            }
        }
    }
}

/// Surface slash-command invocations / stdout as readable text; drop the
/// `<local-command-caveat>` system block. Port of the Mac `sanitizeUserContent`.
fn sanitize_user_content(text: &str) -> Option<String> {
    if text.is_empty() {
        return None;
    }
    if text.starts_with("<local-command-caveat>") {
        return None;
    }
    if let Some(name) = extract_tag(text, "command-name") {
        let args = extract_tag(text, "command-args").unwrap_or_default();
        let args = args.trim();
        return Some(if args.is_empty() {
            name.trim().to_string()
        } else {
            format!("{} {}", name.trim(), args)
        });
    }
    if let Some(stdout) = extract_tag(text, "local-command-stdout") {
        let trimmed = stdout.trim();
        return if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
    }
    Some(text.to_string())
}

fn extract_tag(text: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(text[start..end].to_string())
}
