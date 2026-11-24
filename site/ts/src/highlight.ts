/* Lightweight Elixir & Shell syntax highlighters matching Catppuccin Frappé tokens (HTML string + pure DOM builders). */

function esc(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

const ELIXIR_KW =
  /^(defmodule|defp|def|do|end|fn|if|else|case|when|use|set|on|advise|for_filetype|extension|option|command|keybind|workflow|grant|drawer|action|require_reason_for|warn_above_tokens|true|false|nil)$/;

const SHELL_KW =
  /^(sudo|brew|curl|pacman|pacman-key|apt|dnf|tee|install|open|minga|git|cd|mise|asdf|mix|make|loginctl|jq|echo|set|if|then|fi|exit|export)$/;

interface TokenPart {
  readonly cls: string | null;
  readonly text: string;
}

function tokenizeElixirLine(line: string): readonly TokenPart[] {
  let codePart = line;
  let commentPart = "";
  let inStr = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"' && line[i - 1] !== "\\") inStr = !inStr;
    if (ch === "#" && !inStr) {
      codePart = line.slice(0, i);
      commentPart = line.slice(i);
      break;
    }
  }

  const tokenRe =
    /("(?:\\.|[^"\\])*")|(:[a-z_][a-zA-Z0-9_?!]*)|(\b[a-z_][a-zA-Z0-9_]*:)|(\b[A-Z][a-zA-Z0-9_.]*\b)|(\b\d[\d_]*\b)|(\b[a-z_][a-zA-Z0-9_?!]*\b)|(->|>=|<=|==)/g;
  const parts: TokenPart[] = [];
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = tokenRe.exec(codePart)) !== null) {
    if (m.index > last) parts.push({ cls: null, text: codePart.slice(last, m.index) });
    const tok = m[0];
    if (m[1]) parts.push({ cls: "cst", text: tok });
    else if (m[2] || m[3]) parts.push({ cls: "cat", text: tok });
    else if (m[4]) parts.push({ cls: "cmod", text: tok });
    else if (m[5]) parts.push({ cls: "cnum", text: tok });
    else if (m[6] && ELIXIR_KW.test(tok)) parts.push({ cls: "ckw", text: tok });
    else if (m[7]) parts.push({ cls: "cop", text: tok });
    else parts.push({ cls: null, text: tok });
    last = m.index + tok.length;
  }
  if (last < codePart.length) parts.push({ cls: null, text: codePart.slice(last) });
  if (commentPart) parts.push({ cls: "ccm", text: commentPart });
  return parts;
}

function tokenizeShellLine(line: string): readonly TokenPart[] {
  let codePart = line;
  let commentPart = "";
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === "'" && !inDouble) inSingle = !inSingle;
    else if (ch === '"' && !inSingle && line[i - 1] !== "\\") inDouble = !inDouble;
    else if (ch === "#" && !inSingle && !inDouble && (i === 0 || /\s/.test(line[i - 1]!))) {
      codePart = line.slice(0, i);
      commentPart = line.slice(i);
      break;
    }
  }

  const tokenRe =
    /("(?:\\.|[^"\\])*"|'[^']*')|(https?:\/\/[^\s]+)|(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)|((?:^|\s)--?[A-Za-z0-9][A-Za-z0-9_-]*)|(\|\||&&|>&2|\||>|\[\[|\]\]|==)|(\/[A-Za-z0-9._/-]+|\b[A-Za-z0-9_-]+\/[A-Za-z0-9._/-]+)|(\b[A-Za-z_][A-Za-z0-9_-]*\b)/g;
  const parts: TokenPart[] = [];
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = tokenRe.exec(codePart)) !== null) {
    if (m.index > last) parts.push({ cls: null, text: codePart.slice(last, m.index) });
    const tok = m[0];
    if (m[1]) parts.push({ cls: "cst", text: tok });
    else if (m[2]) parts.push({ cls: "cat", text: tok });
    else if (m[3]) parts.push({ cls: "cmod", text: tok });
    else if (m[4]) {
      const leadSpace = tok.match(/^\s+/)?.[0] ?? "";
      if (leadSpace) parts.push({ cls: null, text: leadSpace });
      parts.push({ cls: "cnum", text: tok.slice(leadSpace.length) });
    } else if (m[5]) parts.push({ cls: "cop", text: tok });
    else if (m[6]) parts.push({ cls: "cmod", text: tok });
    else if (m[7] && SHELL_KW.test(tok)) parts.push({ cls: "ckw", text: tok });
    else parts.push({ cls: null, text: tok });
    last = m.index + tok.length;
  }
  if (last < codePart.length) parts.push({ cls: null, text: codePart.slice(last) });
  if (commentPart) parts.push({ cls: "ccm", text: commentPart });
  return parts;
}

export function highlightElixirLine(line: string): string {
  return tokenizeElixirLine(line)
    .map((p) => (p.cls ? `<span class="${p.cls}">${esc(p.text)}</span>` : esc(p.text)))
    .join("");
}

export function highlightElixirBlock(source: string): string {
  return source.split("\n").map(highlightElixirLine).join("\n");
}

function appendTokens(container: HTMLElement, parts: readonly TokenPart[]): void {
  for (const part of parts) {
    if (part.cls) {
      const span = document.createElement("span");
      span.className = part.cls;
      span.textContent = part.text;
      container.appendChild(span);
    } else {
      container.appendChild(document.createTextNode(part.text));
    }
  }
}

/* Pure DOM API renderers (no innerHTML) safe for live user-typed input strings. */
export function renderElixirLineDom(container: HTMLElement, line: string, plainOnly = false): void {
  container.textContent = "";
  if (plainOnly) {
    container.appendChild(document.createTextNode(line));
    return;
  }
  appendTokens(container, tokenizeElixirLine(line));
}

export function renderElixirBlockDom(container: HTMLElement, source: string): void {
  container.textContent = "";
  const lines = source.split("\n");
  lines.forEach((line, idx) => {
    appendTokens(container, tokenizeElixirLine(line));
    if (idx < lines.length - 1) container.appendChild(document.createTextNode("\n"));
  });
}

export function renderShellBlockDom(container: HTMLElement, source: string): void {
  container.textContent = "";
  const lines = source.split("\n");
  lines.forEach((line, idx) => {
    appendTokens(container, tokenizeShellLine(line));
    if (idx < lines.length - 1) container.appendChild(document.createTextNode("\n"));
  });
}

export function highlightStaticShellBlocks(): void {
  const candidates = document.querySelectorAll<HTMLElement>(
    ".code-tabs pre code, .code-card.is-frappe pre code",
  );
  candidates.forEach((codeEl) => {
    // Skip blocks that already have manual token spans or are managed by the Elixir playground.
    if (codeEl.id === "cfg-preview-code" || codeEl.querySelector("span")) return;
    const raw = codeEl.textContent ?? "";
    if (!raw.trim()) return;
    renderShellBlockDom(codeEl, raw);
  });
}
