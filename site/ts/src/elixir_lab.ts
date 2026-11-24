/* Lesson 04: Interactive "Coming From..." Translator + Live-Themed config.exs Playground. */

import { completeMission } from "./progress.ts";

export type EditorBackground = "lua" | "elisp" | "vscode";
export type MingaTheme = "catppuccin_frappe" | "catppuccin_latte" | "astrodark" | "doom_one" | "one_light";
export type LineNumberMode = "hybrid" | "relative" | "absolute";

export interface ConfigOptions {
  readonly model: "vim" | "cua";
  readonly theme: MingaTheme;
  readonly lines: LineNumberMode;
  readonly tab: 2 | 4;
  readonly gofmt: boolean;
  readonly hook: boolean;
  readonly mcp: boolean;
  readonly ext: boolean;
}

export interface ThemePalette {
  readonly label: string;
  readonly bg: string;
  readonly chrome: string;
  readonly border: string;
  readonly fg: string;
  readonly muted: string;
  readonly kw: string;
  readonly atom: string;
  readonly str: string;
  readonly num: string;
}

export const THEME_PALETTES: Record<MingaTheme, ThemePalette> = {
  catppuccin_frappe: {
    label: "Catppuccin Frappé",
    bg: "#303446",
    chrome: "#292c3c",
    border: "#414559",
    fg: "#c6d0f5",
    muted: "#838ba7",
    kw: "#ca9ee6",
    atom: "#8caaee",
    str: "#a6d189",
    num: "#ef9f76",
  },
  catppuccin_latte: {
    label: "Catppuccin Latte",
    bg: "#eff1f5",
    chrome: "#e6e9ef",
    border: "#ccd0da",
    fg: "#4c4f69",
    muted: "#7c7f93",
    kw: "#8839ef",
    atom: "#1e66f5",
    str: "#40a02b",
    num: "#fe640b",
  },
  astrodark: {
    label: "AstroDark",
    bg: "#1a1d23",
    chrome: "#14171c",
    border: "#2a2f3a",
    fg: "#d8dee9",
    muted: "#7b8496",
    kw: "#c678dd",
    atom: "#61afef",
    str: "#98c379",
    num: "#d19a66",
  },
  doom_one: {
    label: "Doom One",
    bg: "#282c34",
    chrome: "#21242b",
    border: "#3f444a",
    fg: "#bbc2cf",
    muted: "#6d7580",
    kw: "#c678dd",
    atom: "#51afef",
    str: "#98be65",
    num: "#da8548",
  },
  one_light: {
    label: "One Light",
    bg: "#fafafa",
    chrome: "#f0f0f1",
    border: "#dcdfe4",
    fg: "#383a42",
    muted: "#787c8a",
    kw: "#a626a4",
    atom: "#4078f2",
    str: "#50a14f",
    num: "#986801",
  },
};

export const CONFIG_PRESETS: Record<string, { readonly label: string; readonly config: ConfigOptions }> = {
  vim: {
    label: "Minimal Vim",
    config: { model: "vim", theme: "catppuccin_frappe", lines: "relative", tab: 2, gofmt: true, hook: false, mcp: false, ext: true },
  },
  doom: {
    label: "Doom Emacs",
    config: { model: "vim", theme: "doom_one", lines: "hybrid", tab: 2, gofmt: true, hook: false, mcp: true, ext: true },
  },
  cua: {
    label: "CUA Desktop",
    config: { model: "cua", theme: "catppuccin_latte", lines: "absolute", tab: 4, gofmt: false, hook: false, mcp: false, ext: false },
  },
  work: {
    label: "Work Laptop Safety",
    config: { model: "vim", theme: "astrodark", lines: "hybrid", tab: 2, gofmt: true, hook: true, mcp: true, ext: true },
  },
};

export function generateConfigExs(cfg: ConfigOptions): string {
  const out = ["use Minga.Config", ""];
  out.push(`set :theme, :${cfg.theme}`);
  out.push(`set :line_numbers, :${cfg.lines}`);
  out.push(`set :tab_width, ${cfg.tab}`);
  if (cfg.model === "cua") {
    out.push("set :editing_model, :cua");
  }

  if (cfg.gofmt) {
    out.push("");
    out.push("for_filetype :go, tab_width: 4, indent_with: :tabs");
    out.push("");
    out.push("on :after_save, fn _buf, path ->");
    out.push('  if String.ends_with?(path, ".go") do');
    out.push('    System.cmd("gofmt", ["-w", path])');
    out.push("  end");
    out.push("end");
  }

  if (cfg.hook) {
    out.push("");
    out.push("set :agent_hooks, [");
    out.push("  %{");
    out.push('    event: "PreToolUse",');
    out.push('    tool: "shell",');
    out.push('    command: "~/.config/minga/hooks/check-shell-command.sh",');
    out.push("    timeout_ms: 10_000");
    out.push("  }");
    out.push("]");
  }

  if (cfg.mcp) {
    out.push("");
    out.push("set :agent_mcp_servers, [");
    out.push("  %{");
    out.push('    name: "github",');
    out.push('    command: "npx",');
    out.push('    args: ["-y", "@modelcontextprotocol/server-github"],');
    out.push('    env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => System.fetch_env!("GITHUB_TOKEN")}');
    out.push("  }");
    out.push("]");
  }

  if (cfg.ext) {
    out.push("");
    out.push("extension :minga_git_extended,");
    out.push('  hex: "minga_git_extended",');
    out.push('  version: "~> 0.1",');
    out.push("  load_policy: {:on_command, [:git_log]}");
  }

  return out.join("\n");
}

interface TranslationPair {
  readonly id: string;
  readonly concept: string;
  readonly note: string;
  readonly elixir: string;
  readonly source: Record<EditorBackground, string>;
}

const TRANSLATIONS: readonly TranslationPair[] = [
  {
    id: "atom",
    concept: "Named tag (Atom)",
    note: "Leading colon (:name) is a compile-time constant symbol, used for themes, modes, and option names.",
    elixir: "set :theme, :catppuccin_frappe",
    source: {
      lua: 'vim.cmd.colorscheme("catppuccin-frappe")',
      elisp: "(setq doom-theme 'catppuccin-frappe)",
      vscode: '{ "workbench.colorTheme": "Catppuccin Frappe" }',
    },
  },
  {
    id: "kw",
    concept: "Keyword list options",
    note: "Plain key: value pairs replace nested tables or JSON objects in per-filetype rules.",
    elixir: "for_filetype :go, tab_width: 4, indent_with: :tabs",
    source: {
      lua: "vim.bo.tabstop = 4; vim.bo.expandtab = false",
      elisp: "(setq-local tab-width 4 indent-tabs-mode t)",
      vscode: '{ "[go]": { "editor.tabSize": 4, "editor.insertSpaces": false } }',
    },
  },
  {
    id: "fn",
    concept: "Anonymous callback",
    note: "fn args -> body end defines a closure; prefix unused args with _ (_buf) to keep warnings clean.",
    elixir: 'on :after_save, fn _buf, path -> System.cmd("gofmt", ["-w", path]) end',
    source: {
      lua: 'vim.api.nvim_create_autocmd("BufWritePost", { callback = function(ev) ... end })',
      elisp: "(add-hook 'after-save-hook (lambda () (gofmt-before-save)))",
      vscode: '{ "editor.formatOnSave": true }',
    },
  },
  {
    id: "map",
    concept: "Map + tuple policy",
    note: "%{...} is a key-value map; {:on_command, [:git_log]} is a tagged tuple telling Minga when to boot an extension.",
    elixir: 'extension :minga_git_extended, hex: "minga_git_extended", load_policy: {:on_command, [:git_log]}',
    source: {
      lua: '{ "user/git-ext", cmd = { "GitLog" } }',
      elisp: "(use-package git-ext :commands (git-log))",
      vscode: '{ "activationEvents": ["onCommand:git.log"] }',
    },
  },
];

const BG_LABELS: Record<EditorBackground, string> = {
  lua: "Neovim (Lua)",
  elisp: "Emacs (Elisp)",
  vscode: "VS Code (JSON)",
};

function esc(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

export function mountElixirTranslator(root: HTMLElement): void {
  let bg: EditorBackground = "lua";
  let activeId = "atom";

  function render(): void {
    const active = TRANSLATIONS.find((t) => t.id === activeId) ?? TRANSLATIONS[0];
    const rows = TRANSLATIONS.map((pair) => {
      const sel = pair.id === activeId;
      return `
        <button type="button" class="tr-row ${sel ? "is-active" : ""}" data-tr-id="${pair.id}">
          <span class="tr-concept">${esc(pair.concept)}</span>
          <span class="tr-pair">
            <code class="tr-src">${esc(pair.source[bg])}</code>
            <span class="tr-arrow" aria-hidden="true">-&gt;</span>
            <code class="tr-ex">${esc(pair.elixir)}</code>
          </span>
        </button>`;
    }).join("");

    root.innerHTML = `
      <div class="lab-bar">
        <span>INTERACTIVE TRANSLATOR · PICK YOUR CURRENT EDITOR</span>
        <span>Hover or click any row to inspect</span>
      </div>
      <div class="tr-head">
        <div class="seg-group" role="group" aria-label="Source editor">
          <button type="button" class="seg-btn ${bg === "lua" ? "is-active" : ""}" data-tr-bg="lua">Neovim / Lua</button>
          <button type="button" class="seg-btn ${bg === "elisp" ? "is-active" : ""}" data-tr-bg="elisp">Emacs / Elisp</button>
          <button type="button" class="seg-btn ${bg === "vscode" ? "is-active" : ""}" data-tr-bg="vscode">VS Code / JSON</button>
        </div>
        <span class="tr-cols-label">${esc(BG_LABELS[bg])} -&gt; Minga Elixir</span>
      </div>
      <div class="tr-list">${rows}</div>
      <div class="lab-note"><strong>${esc(active?.concept ?? "")}:</strong> ${esc(active?.note ?? "")}</div>`;
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;
    const bgBtn = target.closest<HTMLElement>("[data-tr-bg]");
    if (bgBtn) {
      const next = bgBtn.getAttribute("data-tr-bg");
      if (next === "lua" || next === "elisp" || next === "vscode") {
        bg = next;
        completeMission("elixir", "translator");
        render();
      }
      return;
    }
    const row = target.closest<HTMLElement>("[data-tr-id]");
    if (row) {
      activeId = row.getAttribute("data-tr-id") ?? activeId;
      completeMission("elixir", "translator");
      render();
    }
  });

  render();
}

export function mountElixirPlayground(root: HTMLElement): void {
  let cfg: ConfigOptions = { ...CONFIG_PRESETS.vim!.config };
  let activePreset = "vim";

  function lineNums(mode: LineNumberMode): [string, string, string, string] {
    if (mode === "absolute") return ["14", "15", "16", "17"];
    if (mode === "relative") return ["1", "0", "1", "2"];
    return ["1", "15", "1", "2"];
  }

  function renderPreview(): void {
    const codeEl = root.querySelector<HTMLElement>("#cfg-preview-code");
    const previewEl = root.querySelector<HTMLElement>("[data-theme-preview]");
    if (codeEl) {
      codeEl.textContent = generateConfigExs(cfg);
    }
    if (previewEl) {
      const p = THEME_PALETTES[cfg.theme];
      const [n1, n2, n3, n4] = lineNums(cfg.lines);
      const indent = " ".repeat(cfg.tab);
      previewEl.style.background = p.bg;
      previewEl.style.color = p.fg;
      previewEl.style.borderColor = p.border;
      previewEl.innerHTML = `
        <div class="tp-bar" style="background:${p.chrome};border-bottom:1px solid ${p.border};color:${p.muted};">
          <span>Live preview · ${esc(p.label)}</span>
          <span>${cfg.model === "cua" ? "CUA" : "NORMAL"} · ${cfg.lines} · tab ${cfg.tab}</span>
        </div>
        <div class="tp-code">
          <div class="tp-line"><span class="tp-ln" style="color:${p.muted};">${n1}</span><span><span style="color:${p.kw};">defmodule</span> Retry <span style="color:${p.kw};">do</span></span></div>
          <div class="tp-line tp-cur" style="background:color-mix(in srgb, ${p.kw} 12%, ${p.bg});"><span class="tp-ln" style="color:${p.atom};font-weight:700;">${n2}</span><span>${indent}<span style="color:${p.kw};">def</span> wait_ms(n), <span style="color:${p.kw};">do:</span> min(<span style="color:${p.num};">30_000</span>, <span style="color:${p.num};">250</span> * n)</span></div>
          <div class="tp-line"><span class="tp-ln" style="color:${p.muted};">${n3}</span><span>${indent}<span style="color:${p.kw};">def</span> label, <span style="color:${p.kw};">do:</span> <span style="color:${p.str};">"${esc(cfg.theme)}"</span></span></div>
          <div class="tp-line"><span class="tp-ln" style="color:${p.muted};">${n4}</span><span><span style="color:${p.kw};">end</span></span></div>
        </div>`;
    }

    root.querySelectorAll<HTMLButtonElement>("[data-cfg-preset]").forEach((btn) => {
      btn.classList.toggle("is-active", btn.getAttribute("data-cfg-preset") === activePreset);
    });
  }

  function syncControlsFromConfig(): void {
    const m = root.querySelector<HTMLSelectElement>('[data-cfg-field="model"]');
    const t = root.querySelector<HTMLSelectElement>('[data-cfg-field="theme"]');
    const l = root.querySelector<HTMLSelectElement>('[data-cfg-field="lines"]');
    const tab = root.querySelector<HTMLSelectElement>('[data-cfg-field="tab"]');
    const gofmt = root.querySelector<HTMLInputElement>('[data-cfg-opt="gofmt"]');
    const hook = root.querySelector<HTMLInputElement>('[data-cfg-opt="hook"]');
    const mcp = root.querySelector<HTMLInputElement>('[data-cfg-opt="mcp"]');
    const ext = root.querySelector<HTMLInputElement>('[data-cfg-opt="ext"]');
    if (m) m.value = cfg.model;
    if (t) t.value = cfg.theme;
    if (l) l.value = cfg.lines;
    if (tab) tab.value = String(cfg.tab);
    if (gofmt) gofmt.checked = cfg.gofmt;
    if (hook) hook.checked = cfg.hook;
    if (mcp) mcp.checked = cfg.mcp;
    if (ext) ext.checked = cfg.ext;
  }

  function readControls(): void {
    const m = root.querySelector<HTMLSelectElement>('[data-cfg-field="model"]')?.value;
    const t = root.querySelector<HTMLSelectElement>('[data-cfg-field="theme"]')?.value;
    const l = root.querySelector<HTMLSelectElement>('[data-cfg-field="lines"]')?.value;
    const tab = Number(root.querySelector<HTMLSelectElement>('[data-cfg-field="tab"]')?.value);
    cfg = {
      model: m === "cua" ? "cua" : "vim",
      theme: (t && t in THEME_PALETTES ? t : "catppuccin_frappe") as MingaTheme,
      lines: l === "relative" || l === "absolute" ? l : "hybrid",
      tab: tab === 4 ? 4 : 2,
      gofmt: Boolean(root.querySelector<HTMLInputElement>('[data-cfg-opt="gofmt"]')?.checked),
      hook: Boolean(root.querySelector<HTMLInputElement>('[data-cfg-opt="hook"]')?.checked),
      mcp: Boolean(root.querySelector<HTMLInputElement>('[data-cfg-opt="mcp"]')?.checked),
      ext: Boolean(root.querySelector<HTMLInputElement>('[data-cfg-opt="ext"]')?.checked),
    };
    activePreset = "";
    completeMission("elixir", "theme_preview");
    renderPreview();
  }

  root.addEventListener("click", (event) => {
    const btn = (event.target as HTMLElement | null)?.closest<HTMLElement>("[data-cfg-preset]");
    if (!btn) return;
    const key = btn.getAttribute("data-cfg-preset");
    if (key && CONFIG_PRESETS[key]) {
      activePreset = key;
      cfg = { ...CONFIG_PRESETS[key].config };
      completeMission("elixir", "preset");
      syncControlsFromConfig();
      renderPreview();
    }
  });

  root.addEventListener("change", (event) => {
    const target = event.target as HTMLElement | null;
    if (target?.matches("[data-cfg-field], [data-cfg-opt]")) {
      readControls();
    }
  });

  syncControlsFromConfig();
  renderPreview();
}
