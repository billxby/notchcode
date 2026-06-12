// Which coding agent a session belongs to — the Windows port of the Mac
// `Agent.swift`. Lets Notchcode observe a second first-party agent (OpenAI
// Codex) through the same hooks + transcript-tailing paths without hard-coding
// "claude" everywhere.
//
// Everything agent-specific (config paths, the hook config file, the transcript
// root, the process name, the URL segment, the hook matcher) hangs off this
// enum. Adding a third agent later is "add a variant + fill in the matches."

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Agent {
    Claude,
    Codex,
}

impl Default for Agent {
    fn default() -> Self {
        Agent::Claude
    }
}

impl Agent {
    /// URL path segment / config key: "claude" | "codex".
    pub fn segment(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
        }
    }

    /// Parse from a URL path segment or a frontend string.
    pub fn from_segment(s: &str) -> Option<Self> {
        match s {
            "claude" => Some(Agent::Claude),
            "codex" => Some(Agent::Codex),
            _ => None,
        }
    }

    /// Human label for the UI.
    pub fn display_name(self) -> &'static str {
        match self {
            Agent::Claude => "Claude",
            Agent::Codex => "Codex",
        }
    }

    /// Substring used to recognize the agent's process when resolving the
    /// owning PID of a hook (see winutil::resolve_session_pid).
    pub fn process_name(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
        }
    }

    /// %USERPROFILE%\.claude or %USERPROFILE%\.codex.
    pub fn config_dir(self) -> Option<PathBuf> {
        let home = std::env::var_os("USERPROFILE")?;
        Some(PathBuf::from(home).join(format!(".{}", self.segment())))
    }

    /// The JSON file we additively install hook entries into.
    ///   Claude → ~/.claude/settings.json
    ///   Codex  → ~/.codex/hooks.json   (same {hooks:{Event:[…]}} shape)
    pub fn hook_config_file(self) -> Option<PathBuf> {
        let dir = self.config_dir()?;
        Some(match self {
            Agent::Claude => dir.join("settings.json"),
            Agent::Codex => dir.join("hooks.json"),
        })
    }

    /// Root dir of per-session transcripts.
    ///   Claude → ~/.claude/projects/<slug>/<session-id>.jsonl
    ///   Codex  → ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
    pub fn transcript_root(self) -> Option<PathBuf> {
        let dir = self.config_dir()?;
        Some(match self {
            Agent::Claude => dir.join("projects"),
            Agent::Codex => dir.join("sessions"),
        })
    }

    /// Hook matcher: Claude accepts "*" (all); Codex matchers are regexes, so
    /// "all tools" is ".*".
    pub fn matcher(self) -> &'static str {
        match self {
            Agent::Claude => "*",
            Agent::Codex => ".*",
        }
    }

    /// Namespace a raw, agent-supplied session id so two agents handing us the
    /// same UUID can never collide in the engine's keyed store.
    pub fn session_key(self, raw: &str) -> String {
        format!("{}:{}", self.segment(), raw)
    }
}
