// Lightweight markdown renderer for chat turns — the Windows port of the Mac
// `MarkdownText` in SessionDetailView.swift.
//
// Why not just render `m.text`: a raw string shows users literal `**bold**`,
// backticks, and ANSI escape codes. Why not react-markdown: it pulls a whole
// dependency tree for what is, in practice, a small fixed grammar — paragraphs,
// headers, lists, code fences, and inline bold/italic/code/links cover the real
// shape of Claude/Codex conversations. Tables and blockquotes render as plain
// paragraphs, same as the Mac app.

import { Fragment, ReactNode, useMemo } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";

// ---- Block model --------------------------------------------------------------

type ListItem = { marker: string; content: string };

type Block =
  | { kind: "paragraph"; text: string }
  | { kind: "header"; text: string }
  | { kind: "list"; items: ListItem[] }
  | { kind: "code"; text: string };

// Terminal escape sequences leak into transcripts (e.g. `\x1b[1m` around a
// model name in a command's stdout) and render as "←[1m" garbage. CSI ending
// in any final byte, plus OSC terminated by BEL or ST.
// eslint-disable-next-line no-control-regex
const ANSI_RE = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?/g;

function stripAnsi(s: string): string {
  return s.replace(ANSI_RE, "");
}

// "- x" / "* x" / "+ x" → ("•", "x");  "12. x" → ("12.", "x").
function listItem(line: string): ListItem | null {
  for (const prefix of ["- ", "* ", "+ "]) {
    if (line.startsWith(prefix)) {
      return { marker: "•", content: line.slice(prefix.length) };
    }
  }
  const m = /^(\d{1,3})\. (.*)$/.exec(line);
  if (m) return { marker: `${m[1]}.`, content: m[2] };
  return null;
}

function parseBlocks(text: string): Block[] {
  const result: Block[] = [];
  let paragraph: string[] = [];
  let listItems: ListItem[] = [];
  let codeLines: string[] = [];
  let inCode = false;

  const flushParagraph = () => {
    if (paragraph.length === 0) return;
    result.push({ kind: "paragraph", text: paragraph.join("\n") });
    paragraph = [];
  };
  const flushList = () => {
    if (listItems.length === 0) return;
    result.push({ kind: "list", items: listItems });
    listItems = [];
  };

  for (const rawLine of text.split("\n")) {
    const line = rawLine.trim();

    // Fence toggles win over everything else.
    if (line.startsWith("```")) {
      if (inCode) {
        result.push({ kind: "code", text: codeLines.join("\n") });
        codeLines = [];
        inCode = false;
      } else {
        flushParagraph();
        flushList();
        inCode = true;
      }
      continue;
    }
    if (inCode) {
      codeLines.push(rawLine); // keep original indentation
      continue;
    }

    if (line === "") {
      flushParagraph();
      flushList();
      continue;
    }

    // Headers: "# " through "###### ", rendered uniformly — a chat bubble
    // has no room for a six-level type scale.
    const h = /^#{1,6} (.*)$/.exec(line);
    if (h) {
      flushParagraph();
      flushList();
      result.push({ kind: "header", text: h[1].trim() });
      continue;
    }

    const item = listItem(line);
    if (item) {
      flushParagraph();
      listItems.push(item);
      continue;
    }

    flushList();
    paragraph.push(line);
  }

  // Unterminated fence (mid-stream message) — show what we have.
  if (inCode && codeLines.length > 0) {
    result.push({ kind: "code", text: codeLines.join("\n") });
  }
  flushParagraph();
  flushList();
  return result;
}

// ---- Inline parsing ------------------------------------------------------------

// One pattern per inline style, tried in order: `code` (verbatim, wins over
// everything nested in it), [link](url), **bold**, *italic* / _italic_.
// Underscore italics require non-word boundaries so snake_case_identifiers
// outside backticks don't sprout emphasis (matches CommonMark, and what the
// Mac app's Foundation parser does).
const INLINE_RE =
  /(`[^`]+`)|(\[[^\]]+\]\((?:https?|mailto):[^)\s]+\))|(\*\*[^*]+\*\*)|(\*[^*\s](?:[^*]*[^*\s])?\*|(?<![A-Za-z0-9_])_[^_\s](?:[^_]*[^_\s])?_(?![A-Za-z0-9_]))/;

const LINK_RE = /^\[([^\]]+)\]\(([^)]+)\)$/;

function renderInline(s: string, key = 0): ReactNode {
  const m = INLINE_RE.exec(s);
  if (!m) return s;

  const before = s.slice(0, m.index);
  const after = s.slice(m.index + m[0].length);
  let node: ReactNode;

  if (m[1]) {
    node = <code className="md-code-inline">{m[1].slice(1, -1)}</code>;
  } else if (m[2]) {
    const link = LINK_RE.exec(m[2])!;
    const href = link[2];
    node = (
      <a
        href={href}
        onClick={(e) => {
          e.preventDefault();
          openUrl(href);
        }}
      >
        {renderInline(link[1])}
      </a>
    );
  } else if (m[3]) {
    node = <strong>{renderInline(m[3].slice(2, -2))}</strong>;
  } else {
    node = <em>{renderInline(m[4].slice(1, -1))}</em>;
  }

  return (
    <Fragment key={key}>
      {before}
      {node}
      {renderInline(after, key + 1)}
    </Fragment>
  );
}

// ---- Component -----------------------------------------------------------------

export default function MarkdownText({ text }: { text: string }) {
  // Message text is immutable once recorded (each JSONL line is a complete
  // turn), so memoizing on `text` never goes stale.
  const blocks = useMemo(() => parseBlocks(stripAnsi(text)), [text]);

  return (
    <div className="md">
      {blocks.map((block, i) => {
        switch (block.kind) {
          case "paragraph":
            return (
              <p className="md-p" key={i}>
                {renderInline(block.text)}
              </p>
            );
          case "header":
            return (
              <p className="md-h" key={i}>
                {renderInline(block.text)}
              </p>
            );
          case "list":
            return (
              <div className="md-list" key={i}>
                {block.items.map((item, j) => (
                  <div className="md-li" key={j}>
                    <span
                      className={
                        item.marker === "•" ? "md-marker" : "md-marker md-marker-num"
                      }
                    >
                      {item.marker}
                    </span>
                    <span>{renderInline(item.content)}</span>
                  </div>
                ))}
              </div>
            );
          case "code":
            return (
              // Verbatim — no inline parsing inside fences. The horizontal
              // scroll keeps long lines from blowing the bubble width.
              <pre className="md-pre" key={i}>
                {block.text}
              </pre>
            );
        }
      })}
    </div>
  );
}
