/* Lightweight Elixir + unified diff syntax highlighter matching Catppuccin Frappé tokens. */

function esc(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

const ELIXIR_KW =
  /^(defmodule|defp|def|do|end|fn|if|else|case|when|use|set|on|advise|for_filetype|extension|option|command|keybind|workflow|grant|drawer|action|require_reason_for|warn_above_tokens|true|false|nil)$/;

export function highlightElixirLine(line: string): string {
  // Split comment tail outside strings
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

  const tokenRe = /("(?:\\.|[^"\\])*")|(:[a-z_][a-zA-Z0-9_?!]*)|(\b[A-Z][a-zA-Z0-9_.]*\b)|(\b\d[\d_]*\b)|(\b[a-z_][a-zA-Z0-9_?!]*\b)|(->|>=|<=|==)/g;
  let out = "";
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = tokenRe.exec(codePart)) !== null) {
    if (m.index > last) out += esc(codePart.slice(last, m.index));
    const tok = m[0];
    if (m[1]) {
      out += `<span class="cst">${esc(tok)}</span>`;
    } else if (m[2]) {
      out += `<span class="cat">${esc(tok)}</span>`;
    } else if (m[3]) {
      out += `<span class="cmod">${esc(tok)}</span>`;
    } else if (m[4]) {
      out += `<span class="cnum">${esc(tok)}</span>`;
    } else if (m[5] && ELIXIR_KW.test(tok)) {
      out += `<span class="ckw">${esc(tok)}</span>`;
    } else if (m[6]) {
      out += `<span class="cop">${esc(tok)}</span>`;
    } else {
      out += esc(tok);
    }
    last = m.index + tok.length;
  }
  if (last < codePart.length) out += esc(codePart.slice(last));
  if (commentPart) out += `<span class="ccm">${esc(commentPart)}</span>`;
  return out;
}

export function highlightElixirBlock(source: string): string {
  return source.split("\n").map(highlightElixirLine).join("\n");
}
