/* Why Minga interactive widgets: Layout Width Comparator + Personalized "I Currently Use..." Comparison Lens. */

import { highlightElixirLine } from "./highlight.ts";

export type LayoutMode = "ide" | "minga_rest" | "minga_drawer";
export type EditorLensId = "all" | "cursor" | "zed" | "herdr" | "neovim" | "emacs";

export interface LayoutMetrics {
  readonly mode: LayoutMode;
  readonly title: string;
  readonly codeWidthPct: number;
  readonly codeHeightPct: number;
  readonly areaPct: number;
  readonly columnsAt1440: number;
  readonly summary: string;
}

export const LAYOUT_MODES: Record<LayoutMode, LayoutMetrics> = {
  ide: {
    mode: "ide",
    title: "Typical AI IDE (Default layout)",
    codeWidthPct: 48,
    codeHeightPct: 68,
    areaPct: 33,
    columnsAt1440: 78,
    summary: "Activity rail, permanent file tree, tab strip, right chat dock, and bottom terminal leave under a third of your monitor for actual code.",
  },
  minga_rest: {
    mode: "minga_rest",
    title: "Minga at Rest (v0.1.0 minimal UI)",
    codeWidthPct: 100,
    codeHeightPct: 94,
    areaPct: 94,
    columnsAt1440: 164,
    summary: "Plain title bar, full-width code with Twist authorship gutter, and one prioritized modeline. Nearly 3x the visible code area by default.",
  },
  minga_drawer: {
    mode: "minga_drawer",
    title: "Minga + On-Demand Drawer (SPC ,)",
    codeWidthPct: 100,
    codeHeightPct: 66,
    areaPct: 66,
    columnsAt1440: 164,
    summary: "One drawer at a time opens at the bottom without squeezing your code's horizontal width. Press q or Esc to return immediately to 94%.",
  },
};

export interface EditorLensCard {
  readonly id: EditorLensId;
  readonly label: string;
  readonly tableColIndex: number | null;
  readonly transfers: string;
  readonly whatChanges: string;
  readonly whenToStay: string;
  readonly starterConfig: string;
}

export const EDITOR_LENSES: Record<EditorLensId, EditorLensCard> = {
  all: {
    id: "all",
    label: "All editors",
    tableColIndex: null,
    transfers: "Compare every tool side by side below, or pick the editor you use today for a direct migration verdict.",
    whatChanges: "Minga unifies native macOS + Go terminal rendering, isolated BEAM processes, staged agent edits, and Elixir customization.",
    whenToStay: "Pick your current editor above to see the strongest honest case for staying on it.",
    starterConfig: "brew install --cask jsmestad/minga/minga-mac",
  },
  cursor: {
    id: "cursor",
    label: "Cursor / VS Code",
    tableColIndex: 1,
    transfers: "Enable CUA desktop shortcuts (Cmd+C/V/X/Z/Shift+Z, Cmd+P, Cmd+S) and click any visible control with the mouse.",
    whatChanges: "Replaces Electron and permanent panels with native macOS + SSH terminal clients, isolated BEAM processes, and Elixir customization without an RPC extension wall.",
    whenToStay: "Stay on Cursor or VS Code if you rely daily on inline Tab autocomplete prediction, cloud background agents, or niche VS Code marketplace extensions.",
    starterConfig: "set :editing_model, :cua",
  },
  zed: {
    id: "zed",
    label: "Zed",
    tableColIndex: 2,
    transfers: "Native GPU-accelerated speed on macOS, crisp minimal styling, tree-sitter syntax highlighting, and multi-provider agent support.",
    whatChanges: "Adds a first-party Go terminal client for SSH parity, full Elixir programmability (command advice, hooks, extensions), and per-process Erlang fault isolation.",
    whenToStay: "Stay on Zed if you need Windows/Linux desktop GUIs today, editable multibuffer inline diffs right now, or ACP integration with flat-rate vendor CLIs.",
    starterConfig: "set :theme, :astrodark",
  },
  herdr: {
    id: "herdr",
    label: "tmux / Herdr",
    tableColIndex: 3,
    transfers: "Persistent headless remote sessions (minga --headless + minga attach ssh://), keyboard-driven workflows, and multi-agent status views.",
    whatChanges: "Agents edit against your open buffers via revision-checked staged overlays and 3-way merge instead of writing blind on disk or forcing separate Git worktrees.",
    whenToStay: "Stay on Herdr or tmux if your top priority is running Anthropic Claude Code and OpenAI Codex CLI directly on flat-rate vendor subscriptions.",
    starterConfig: "minga --headless && minga attach ssh://devbox",
  },
  neovim: {
    id: "neovim",
    label: "Neovim",
    tableColIndex: null,
    transfers: "Vim motions, text objects (iw, i\", a{), registers, macros, counts, dot repeat, LSP, and first-class terminal usage carry straight over.",
    whatChanges: "Replaces a single Lua event loop and a dozen glued plugins with native macOS + Go TUI parity, Erlang process isolation, and built-in staged agent review.",
    whenToStay: "Stay on Neovim if you rely on 15ms LuaJIT startup on remote Linux boxes and a mature plugin stack (fugitive, oil.nvim, telescope, gitsigns) you already tuned.",
    starterConfig: "set :line_numbers, :relative",
  },
  emacs: {
    id: "emacs",
    label: "Emacs / Doom",
    tableColIndex: null,
    transfers: "Spacebar leader menus (SPC), command advice (:before, :after, :around, :override), hooks, special review buffers, and configuring the editor in its own language.",
    whatChanges: "Moves from one Lisp thread to preemptive BEAM processes per file, hook, extension, and MCP server so slow background work never stalls typing.",
    whenToStay: "Stay on Emacs if you live inside org-mode, magit, TRAMP, or live eval-defun patching of already-loaded packages (Minga reloads compiled extensions on restart per ADR-0003).",
    starterConfig: "set :theme, :doom_one",
  },
};

function esc(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function mountLayoutComparator(root: HTMLElement): void {
  let mode: LayoutMode = "ide";

  function render(): void {
    const m = LAYOUT_MODES[mode];
    const mingaLines: readonly { readonly ln: number; readonly hl?: boolean; readonly text: string }[] = [
      { ln: 234, text: "defmodule MingaAgent.Retry do" },
      { ln: 235, text: "  @max_backoff_ms 30_000" },
      { ln: 236, text: "" },
      { ln: 237, text: "  def classify_status(status, headers) do" },
      { ln: 238, hl: true, text: "    case status do" },
      { ln: 239, hl: true, text: "      429 -> {:rate_limited, parse_retry_after(headers)}" },
      { ln: 240, hl: true, text: "      529 -> {:overloaded, backoff_ms(2)}  # 164 unobstructed columns" },
      { ln: 241, hl: true, text: "      code when code >= 500 -> {:retryable, backoff_ms(1)}" },
      { ln: 242, text: "      _ -> {:fatal, status}" },
      { ln: 243, text: "    end" },
      { ln: 244, text: "  end" },
      { ln: 245, text: "" },
      { ln: 246, text: "  defp backoff_ms(attempt), do: min(@max_backoff_ms, 250 * attempt)" },
      { ln: 247, text: "end" },
    ];

    const visibleLines = mode === "minga_drawer" ? mingaLines.slice(3, 11) : mingaLines;
    const mingaCodeHtml = visibleLines
      .map(
        (l) =>
          `<div class="${l.hl ? "wf-hl" : ""}"><span class="wf-ln">${l.ln}</span>${l.text ? highlightElixirLine(l.text) : "&nbsp;"}</div>`,
      )
      .join("");

    const wireframe =
      mode === "ide"
        ? `
          <div class="wf-ide">
            <div class="wf-rail">
              <span>Files</span>
              <span>Search</span>
              <span>Git</span>
              <span>Debug</span>
              <span>Exts</span>
              <span>AI</span>
            </div>
            <div class="wf-tree">
              <strong class="wf-panel-head">EXPLORER</strong>
              <span>▾ lib/</span>
              <span>&nbsp; ▾ minga_agent/</span>
              <span class="wf-file-active">&nbsp;&nbsp;&nbsp; retry.ex</span>
              <span>&nbsp;&nbsp;&nbsp; router.ex</span>
              <span>&nbsp;&nbsp;&nbsp; session.ex</span>
              <span>▾ test/</span>
              <span>&nbsp; retry_test.exs</span>
              <span>▸ config/</span>
              <span>▸ docs/</span>
            </div>
            <div class="wf-center">
              <div class="wf-tabs"><span>retry.ex ×</span><span>router.ex ×</span><span>session.ex ×</span><span>+8</span></div>
              <div class="wf-code is-cramped">
                <div><span class="wf-ln">237</span>${highlightElixirLine("def classify_status(status,")}</div>
                <div><span class="wf-ln">   </span>${highlightElixirLine("    headers) do")}</div>
                <div><span class="wf-ln">238</span>${highlightElixirLine("  case status do")}</div>
                <div><span class="wf-ln">239</span>${highlightElixirLine("    429 -> {:rate_limited,")}</div>
                <div><span class="wf-ln">   </span>${highlightElixirLine("      parse_retry_after(...)}")}</div>
                <div><span class="wf-ln">240</span>${highlightElixirLine("    529 -> {:overloaded,")}</div>
                <div><span class="wf-ln">   </span>${highlightElixirLine("      backoff_ms(2)}")}</div>
              </div>
              <div class="wf-term">
                <div class="wf-term-tabs"><span>PROBLEMS (3)</span><span>OUTPUT</span><span class="is-on">TERMINAL</span><span>DEBUG</span></div>
                <div>$ mix test test/minga_agent/retry_test.exs</div>
                <div class="wf-term-dim">Running ExUnit... (bottom dock takes 28% height)</div>
              </div>
            </div>
            <div class="wf-chat">
              <strong class="wf-panel-head">AI CHAT SIDEBAR</strong>
              <div class="wf-chat-msg">User: Handle HTTP 529 overloaded responses.</div>
              <div class="wf-chat-msg is-ai">Agent: Applying edits across 2 files...</div>
              <div class="wf-chat-box">Ask anything... (360px permanent dock)</div>
            </div>
          </div>`
        : `
          <div class="wf-minga">
            <div class="wf-m-title"><span>minga</span><span>retry.ex · lib/minga_agent/retry.ex</span></div>
            <div class="wf-code is-wide">${mingaCodeHtml}</div>
            ${
              mode === "minga_drawer"
                ? `<div class="wf-drawer">
                    <div class="wf-drawer-head"><span class="wf-drawer-title">Switcher (SPC ,)</span><span>q / esc returns to 94% code area</span></div>
                    <div class="wf-drawer-row"><span class="wf-drawer-file">retry.ex</span> <span class="wf-drawer-meta">· Changed · Minga change 1/2</span></div>
                    <div class="wf-drawer-row"><span class="wf-drawer-file">router.ex</span> <span class="wf-drawer-meta">· Pinned · SPC 1</span></div>
                    <div class="wf-drawer-row"><span class="wf-drawer-file">config.exs</span> <span class="wf-drawer-meta">· Recent · 2m ago</span></div>
                  </div>`
                : ""
            }
            <div class="wf-m-modeline"><span>NORMAL</span><span>retry.ex</span><span class="ml-minga">change 1/2</span><span>elixir · 240:31</span></div>
          </div>`;

    root.innerHTML = `
      <div class="story-box">
        <div class="story-bar">
          <span>INTERACTIVE COMPARISON · 1440×900 WORKSPACE BUDGET</span>
          <div class="seg-group" role="group" aria-label="Compare editor workspace layouts">
            <button type="button" class="seg-btn ${mode === "ide" ? "is-active" : ""}" data-lc-mode="ide">Typical AI IDE</button>
            <button type="button" class="seg-btn ${mode === "minga_rest" ? "is-active" : ""}" data-lc-mode="minga_rest">Minga at Rest</button>
            <button type="button" class="seg-btn ${mode === "minga_drawer" ? "is-active" : ""}" data-lc-mode="minga_drawer">Minga + Drawer (SPC ,)</button>
          </div>
        </div>
        <div class="wf-stage">${wireframe}</div>
        <div class="wf-metrics">
          <div class="wf-metric">
            <span>CODE WIDTH</span>
            <strong>${m.codeWidthPct}% (${m.columnsAt1440} cols)</strong>
          </div>
          <div class="wf-metric">
            <span>USABLE CODE AREA</span>
            <strong class="${mode === "ide" ? "is-warn" : "is-good"}">${m.areaPct}% of viewport</strong>
          </div>
          <p class="wf-summary">${esc(m.summary)}</p>
        </div>
      </div>
    `;
  }

  root.addEventListener("click", (event) => {
    const btn = (event.target as HTMLElement | null)?.closest<HTMLElement>("[data-lc-mode]");
    if (!btn) return;
    const next = btn.getAttribute("data-lc-mode") as LayoutMode | null;
    if (next && next in LAYOUT_MODES) {
      mode = next;
      render();
    }
  });

  render();
}

export function mountCompareLens(root: HTMLElement): void {
  let active: EditorLensId = "all";
  const section = root.closest("section");
  const table = section?.querySelector<HTMLTableElement>(".table-compare");

  function render(): void {
    const lens = EDITOR_LENSES[active];
    const buttons = (Object.keys(EDITOR_LENSES) as EditorLensId[])
      .map(
        (id) =>
          `<button type="button" class="seg-btn ${id === active ? "is-active" : ""}" data-cl-id="${id}">${EDITOR_LENSES[id].label}</button>`,
      )
      .join("");

    const detailCard =
      active === "all"
        ? ""
        : `<div class="lens-card">
            <div class="lens-col">
              <span class="lens-k">WHAT TRANSFERS DIRECTLY</span>
              <p>${esc(lens.transfers)}</p>
            </div>
            <div class="lens-col">
              <span class="lens-k">WHAT MINGA CHANGES</span>
              <p>${esc(lens.whatChanges)}</p>
            </div>
            <div class="lens-col">
              <span class="lens-k">HONEST CASE TO STAY ON ${esc(lens.label.toUpperCase())}</span>
              <p>${esc(lens.whenToStay)}</p>
            </div>
            <div class="lens-foot">
              <span>First step:</span>
              <code>${esc(lens.starterConfig)}</code>
            </div>
          </div>`;

    root.innerHTML = `
      <div class="story-box lens-box">
        <div class="story-bar">
          <span>I CURRENTLY USE...</span>
          <div class="seg-group" role="group" aria-label="Filter comparison by your current editor">${buttons}</div>
        </div>
        ${detailCard}
      </div>
    `;

    if (table) {
      const col = lens.tableColIndex;
      table.querySelectorAll("tr").forEach((row) => {
        const cells = Array.from(row.children) as HTMLElement[];
        cells.forEach((cell, idx) => {
          cell.classList.remove("is-lens-focus", "is-lens-dim");
          if (col !== null) {
            if (idx === col || idx === 4) {
              cell.classList.add("is-lens-focus");
            } else if (idx > 0) {
              cell.classList.add("is-lens-dim");
            }
          }
        });
      });
    }
  }

  root.addEventListener("click", (event) => {
    const btn = (event.target as HTMLElement | null)?.closest<HTMLElement>("[data-cl-id]");
    if (!btn) return;
    const id = btn.getAttribute("data-cl-id") as EditorLensId | null;
    if (id && id in EDITOR_LENSES) {
      active = id;
      render();
    }
  });

  render();
}
