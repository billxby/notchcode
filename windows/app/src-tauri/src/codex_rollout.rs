// Incremental parser for OpenAI Codex rollout transcripts — the Windows port of
// the Mac `CodexRolloutParser.swift`:
//   %USERPROFILE%\.codex\sessions\YYYY\MM\DD\rollout-<timestamp>-<uuid>.jsonl
//
// Codex's rollout format differs from Claude Code's JSONL, so this is a separate
// decoder, but it produces the SAME engine-facing `sessions::ParseResult` so the
// watcher → engine path is identical for both agents.
//
// Rollout line shape:  { "timestamp": "<UTC>", "type": "<T>", "payload": {…} }
//   type "session_meta"  → payload.cwd          (project)
//   type "response_item" → payload.type=="message" → role + content[] text
//   type "event_msg"     → payload.type=="token_count" → token usage
//
// Incremental cursor + rotation handling mirror `claude_jsonl::parse_new`. Codex
// rollouts can reach GBs and are world-readable, so we always tail from the last
// offset and never load a whole file.
//
// Token accounting caveat: `token_count` events may carry both a cumulative
// `total_token_usage` and a per-turn `last_token_usage`. We use the per-turn
// delta so summing across events is correct. Verify against a real rollout file.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::cost::{Model, Usage};
use crate::sessions::{open_with_retry, Lifecycle, ParseResult, Role};

use std::io::{Read, Seek, SeekFrom};

#[derive(Deserialize)]
struct RolloutLine {
    #[serde(rename = "type")]
    kind: Option<String>,
    payload: Option<Payload>,
}

#[derive(Deserialize)]
struct Payload {
    // session_meta
    cwd: Option<String>,
    // model slug, when present (session_meta / turn_context)
    model: Option<String>,
    // response_item (message) / event_msg both nest a "type"
    #[serde(rename = "type")]
    inner_type: Option<String>,
    role: Option<String>,
    content: Option<Vec<ContentBlock>>,
    // event_msg token_count — usage may sit under any of these
    info: Option<TokenInfo>,
    usage: Option<TokenUsage>,
    last_token_usage: Option<TokenUsage>,
    #[allow(dead_code)]
    total_token_usage: Option<TokenUsage>,
    // or inlined directly
    input_tokens: Option<u64>,
    cached_input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    reasoning_output_tokens: Option<u64>,
}

#[derive(Deserialize)]
struct ContentBlock {
    #[serde(rename = "type")]
    kind: Option<String>,
    text: Option<String>,
}

#[derive(Deserialize)]
struct TokenInfo {
    last_token_usage: Option<TokenUsage>,
    #[allow(dead_code)]
    total_token_usage: Option<TokenUsage>,
}

#[derive(Deserialize, Clone, Copy, Default)]
struct TokenUsage {
    input_tokens: Option<u64>,
    cached_input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    reasoning_output_tokens: Option<u64>,
}

/// Read new bytes since last call and extract project + messages + usage.
/// Incremental cursor / rotation handling matches `claude_jsonl::parse_new`.
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

    // Active model, learned from session_meta / turn_context and applied to
    // subsequent token_count events. Default to the original Codex model.
    let mut model = String::from("gpt-5-codex");
    for line in buf[..=last_nl].split(|&b| b == b'\n') {
        if line.is_empty() {
            continue;
        }
        decode_line(line, &mut model, &mut result);
    }
    result
}

fn decode_line(line: &[u8], model: &mut String, result: &mut ParseResult) {
    let Ok(parsed) = serde_json::from_slice::<RolloutLine>(line) else {
        return;
    };
    let Some(payload) = parsed.payload else {
        return;
    };

    // Capture the model wherever it appears.
    if let Some(m) = payload.model.as_deref() {
        if !m.is_empty() {
            *model = m.to_string();
        }
    }

    match parsed.kind.as_deref() {
        Some("session_meta") => {
            if let Some(cwd) = payload.cwd.as_deref() {
                if !cwd.is_empty() {
                    result.project = Some(project_from_cwd(cwd));
                }
            }
        }
        Some("response_item") => {
            // Only "message" items carry conversation text; tool calls dropped.
            if payload.inner_type.as_deref() != Some("message") {
                return;
            }
            let role = match payload.role.as_deref() {
                Some("user") => Role::User,
                Some("assistant") => Role::Assistant,
                _ => return,
            };
            let Some(blocks) = payload.content else {
                return;
            };
            let text = blocks
                .iter()
                .filter(|b| {
                    matches!(
                        b.kind.as_deref(),
                        Some("text") | Some("input_text") | Some("output_text")
                    )
                })
                .filter_map(|b| b.text.clone())
                .collect::<Vec<_>>()
                .join("\n");
            let text = text.trim();
            if !text.is_empty() {
                result.messages.push((role, text.to_string()));
            }
        }
        Some("event_msg") => {
            // Turn-boundary signals drive the session's running/idle status
            // (Codex's hooks can't — see sessions::Lifecycle). token_count
            // drives cost. Everything else (agent_message, …) is ignored.
            match payload.inner_type.as_deref() {
                Some("task_started") => {
                    result.lifecycle.push(Lifecycle::TurnStarted);
                    return;
                }
                Some("task_complete") => {
                    result.lifecycle.push(Lifecycle::TurnCompleted);
                    return;
                }
                Some("token_count") => {}
                _ => return,
            }
            // Prefer the per-turn delta so summing across events is correct.
            let u = payload
                .last_token_usage
                .or_else(|| payload.info.as_ref().and_then(|i| i.last_token_usage))
                .or(payload.usage)
                .or_else(|| {
                    payload.input_tokens.map(|_| TokenUsage {
                        input_tokens: payload.input_tokens,
                        cached_input_tokens: payload.cached_input_tokens,
                        output_tokens: payload.output_tokens,
                        reasoning_output_tokens: payload.reasoning_output_tokens,
                    })
                });
            let Some(u) = u else {
                return;
            };
            // Map Codex's breakdown onto the 5-lane Usage:
            //   input        → input_tokens
            //   cached_input → cache_read_tokens (discounted lane)
            //   output + reasoning_output → output_tokens
            //   (no cache-WRITE concept on OpenAI → cache_create lanes stay 0)
            let usage = Usage {
                input_tokens: u.input_tokens.unwrap_or(0),
                output_tokens: u.output_tokens.unwrap_or(0) + u.reasoning_output_tokens.unwrap_or(0),
                cache_create_5m_tokens: 0,
                cache_create_1h_tokens: 0,
                cache_read_tokens: u.cached_input_tokens.unwrap_or(0),
            };
            if usage.input_tokens + usage.output_tokens + usage.cache_read_tokens == 0 {
                return;
            }
            result.usages.push((usage, Model::from_wire(Some(model))));
        }
        _ => {}
    }
}

fn project_from_cwd(cwd: &str) -> String {
    cwd.trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(cwd)
        .to_string()
}

/// Extract the trailing UUID from `rollout-<timestamp>-<uuid>.jsonl` (the final
/// five hyphen-delimited groups). Matches the `session_id` Codex sends in hook
/// payloads so the two ingestion paths key to the same session. Falls back to
/// the full stem if no UUID is found.
pub fn session_id_from_path(path: &Path) -> Option<String> {
    let stem = path.file_stem().and_then(|s| s.to_str())?;
    let parts: Vec<&str> = stem.split('-').collect();
    if parts.len() >= 5 {
        let candidate = parts[parts.len() - 5..].join("-");
        if candidate.len() == 36 {
            return Some(candidate);
        }
    }
    Some(stem.to_string())
}

/// True for `rollout-*.jsonl` files.
pub fn is_rollout_file(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()) == Some("jsonl")
        && path
            .file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.starts_with("rollout-"))
            .unwrap_or(false)
}
