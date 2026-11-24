/* Why Minga interactive widgets: Layout Width Comparator + Personalized "I Currently Use..." Comparison Lens. */

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
    const wireframe =
      mode === "ide"
        ? `
          <div class="wf-ide">
            <div class="wf-rail">Rail<br>48px</div>
            <div class="wf-tree">
              <strong>EXPLORER</strong>
              <span>▾ lib/</span>
              <span>&nbsp; retry.ex</span>
              <span>&nbsp; router.ex</span>
              <span>▾ test/</span>
            </div>
            <div class="wf-center">
              <div class="wf-tabs"><span>retry.ex ×</span><span>router.ex ×</span><span>config.exs ×</span><span>+6</span></div>
              <div class="wf-code is-cramped">
                <div>238  case status do</div>
                <div>239    429 -&gt; {:rate_limited,</div>
                <div>       parse_retry_after(...)}</div>
                <div>240    529 -&gt; {:overloaded, ...}</div>
              </div>
              <div class="wf-term">TERMINAL · PROBLEMS · OUTPUT · DEBUG (24% height)</div>
            </div>
            <div class="wf-chat">
              <strong>AI CHAT DOCK</strong>
              <span>360px permanent</span>
              <span>sidebar eating</span>
              <span>code columns</span>
            </div>
          </div>`
        : `
          <div class="wf-minga">
            <div class="wf-m-title"><span>minga</span><span>retry.ex · lib/minga_agent</span></div>
            <div class="wf-code is-wide">
              <div><span class="wf-ln">237</span> def classify_status(status, headers) do</div>
              <div class="wf-hl"><span class="wf-ln">238</span>   case status do</div>
              <div class="wf-hl"><span class="wf-ln">239</span>     429 -&gt; {:rate_limited, parse_retry_after(headers)}</div>
              <div class="wf-hl"><span class="wf-ln">240</span>     529 -&gt; {:overloaded, backoff_ms(2)} <span class="wf-muted"># 164 unobstructed columns</span></div>
              <div class="wf-hl"><span class="wf-ln">241</span>     code when code &gt;= 500 -&gt; {:retryable, backoff_ms(1)}</div>
              <div><span class="wf-ln">242</span>     _ -&gt; {:fatal, status}</div>
            </div>
            ${
              mode === "minga_drawer"
                ? `<div class="wf-drawer">
                    <div class="wf-drawer-head"><strong>Switcher (SPC ,)</strong><span>q / esc returns to 94% code area</span></div>
                    <div class="wf-drawer-row"><strong>retry.ex</strong> · Changed · Minga change 1/2</div>
                    <div class="wf-drawer-row"><strong>router.ex</strong> · Pinned · SPC 1</div>
                  </div>`
                : ""
            }
            <div class="wf-m-modeline"><span>NORMAL</span><span>retry.ex</span><span>change 1/2</span><span>elixir · 240:31</span></div>
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
