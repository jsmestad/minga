/*
 * Lesson 04: the settings translator and the config builder.
 *
 * Every word a reader sees is in site/learn/elixir.html: the four rows, their snippets for each editor, the explanations, the option labels and the
 * steps after Copy. This file holds ids, option values and preview colours. It changes classes, attributes and text in place and never rebuilds a control,
 * so focus stays on the control the reader just used.
 */

import { renderElixirBlockDom } from "./highlight.ts";
import { readLabCopy } from "./lab/copy.ts";
import { completeMission } from "./progress.ts";

/* The translator. */

export const SOURCE_EDITORS = ["lua", "elisp", "vscode"] as const;
export type SourceEditor = (typeof SOURCE_EDITORS)[number];

/** One id per row of the translator, in page order. The page holds a `data-tr-row` element for each. */
export const TRANSLATOR_ROWS = ["theme", "filetype", "format", "key"] as const;
export type TranslatorRow = (typeof TRANSLATOR_ROWS)[number];

export interface TranslatorState {
  readonly editor: SourceEditor | null;
  readonly row: TranslatorRow | null;
}

export const TRANSLATOR_START: TranslatorState = { editor: null, row: null };

function isSourceEditor(value: string | undefined): value is SourceEditor {
  return (SOURCE_EDITORS as readonly string[]).includes(value ?? "");
}

function isTranslatorRow(value: string | undefined): value is TranslatorRow {
  return (TRANSLATOR_ROWS as readonly string[]).includes(value ?? "");
}

export function chooseEditor(state: TranslatorState, editor: SourceEditor): TranslatorState {
  return { ...state, editor };
}

/** Opens a row's explanation. Selecting the open row closes it. */
export function selectRow(state: TranslatorState, row: TranslatorRow): TranslatorState {
  return { ...state, row: state.row === row ? null : row };
}

/** The reader has translated a setting once their editor is chosen and one row is open: their own line sits beside the Minga line and its explanation. */
export function hasTranslated(state: TranslatorState): boolean {
  return state.editor !== null && state.row !== null;
}

/** Safari on macOS does not focus a button on a pointer click, so the next key press would go to the page. Focus the control the reader used. */
function keepFocus(control: HTMLElement): void {
  if (document.activeElement !== control) control.focus();
}

export function mountElixirTranslator(root: HTMLElement): void {
  const editorButtons = Array.from(root.querySelectorAll<HTMLButtonElement>("[data-tr-editor]"));
  const items = Array.from(root.querySelectorAll<HTMLElement>("[data-tr-row]"));
  let state = TRANSLATOR_START;

  function apply(next: TranslatorState): void {
    state = next;
    if (state.editor) root.dataset.editor = state.editor;
    for (const button of editorButtons) {
      const on = button.dataset.trEditor === state.editor;
      button.classList.toggle("is-active", on);
      button.setAttribute("aria-pressed", String(on));
    }
    for (const item of items) {
      const on = item.dataset.trRow === state.row;
      item.classList.toggle("is-active", on);
      item.querySelector(".tr-row")?.setAttribute("aria-expanded", String(on));
    }
    if (hasTranslated(state)) completeMission("elixir", "translated");
  }

  for (const button of editorButtons) {
    const editor = button.dataset.trEditor;
    if (!isSourceEditor(editor)) continue;
    button.addEventListener("click", () => {
      keepFocus(button);
      apply(chooseEditor(state, editor));
    });
  }

  for (const item of items) {
    const row = item.dataset.trRow;
    const button = item.querySelector<HTMLButtonElement>(".tr-row");
    if (!button || !isTranslatorRow(row)) continue;
    button.addEventListener("click", () => {
      keepFocus(button);
      apply(selectRow(state, row));
    });
    button.disabled = false;
  }
}

/* The config builder. */

export const MINGA_THEMES = ["catppuccin_frappe", "catppuccin_latte", "astrodark", "doom_one", "one_light"] as const;
export type MingaTheme = (typeof MINGA_THEMES)[number];

export const LINE_NUMBER_MODES = ["relative", "absolute", "none"] as const;
export type LineNumberMode = (typeof LINE_NUMBER_MODES)[number];

export const GO_TAB_WIDTHS = [2, 4, 8] as const;
export type GoTabWidth = (typeof GO_TAB_WIDTHS)[number];

export interface ConfigOptions {
  readonly theme: MingaTheme;
  readonly lines: LineNumberMode;
  readonly goTab: GoTabWidth;
  readonly goFormat: boolean;
}

/** The builder's starting values. The page's static config and preview show the same ones. */
export const DEFAULT_CONFIG: ConfigOptions = { theme: "catppuccin_frappe", lines: "relative", goTab: 8, goFormat: true };

export interface ConfigFields {
  readonly theme?: string | undefined;
  readonly lines?: string | undefined;
  readonly goTab?: string | undefined;
  readonly goFormat?: boolean | undefined;
}

/** Reads form values into options. A value the builder does not offer falls back to the default, so the output is always a config the lesson has checked. */
export function parseConfig(fields: ConfigFields): ConfigOptions {
  const theme = MINGA_THEMES.find((name) => name === fields.theme) ?? DEFAULT_CONFIG.theme;
  const lines = LINE_NUMBER_MODES.find((mode) => mode === fields.lines) ?? DEFAULT_CONFIG.lines;
  const goTab = GO_TAB_WIDTHS.find((width) => String(width) === fields.goTab) ?? DEFAULT_CONFIG.goTab;
  return { theme, lines, goTab, goFormat: fields.goFormat ?? DEFAULT_CONFIG.goFormat };
}

export function generateConfigExs(cfg: ConfigOptions): string {
  const go = [`tab_width: ${cfg.goTab}`, "indent_with: :tabs"];
  if (cfg.goFormat) go.push("format_on_save: true");
  return [
    "use Minga.Config",
    "",
    `set :theme, :${cfg.theme}`,
    `set :line_numbers, :${cfg.lines}`,
    "",
    `for_filetype :go, ${go.join(", ")}`,
  ].join("\n");
}

/** The gutter of the four-line preview, which shows lines 14 to 17 of a file with the cursor on line 15. */
export function previewLineNumbers(mode: LineNumberMode): readonly [string, string, string, string] {
  switch (mode) {
    case "absolute":
      return ["14", "15", "16", "17"];
    case "relative":
      return ["1", "0", "1", "2"];
    case "none":
      return ["", "", "", ""];
  }
}

export interface ThemePalette {
  readonly bg: string;
  readonly chrome: string;
  readonly border: string;
  readonly fg: string;
  readonly muted: string;
  readonly kw: string;
  readonly cursor: string;
  readonly num: string;
}

export const THEME_PALETTES: Record<MingaTheme, ThemePalette> = {
  catppuccin_frappe: { bg: "#303446", chrome: "#292c3c", border: "#414559", fg: "#c6d0f5", muted: "#838ba7", kw: "#ca9ee6", cursor: "#8caaee", num: "#ef9f76" },
  catppuccin_latte: { bg: "#eff1f5", chrome: "#e6e9ef", border: "#ccd0da", fg: "#4c4f69", muted: "#7c7f93", kw: "#8839ef", cursor: "#1e66f5", num: "#d35400" },
  astrodark: { bg: "#1a1d23", chrome: "#14171c", border: "#2a2f3a", fg: "#adb0bb", muted: "#696c76", kw: "#dd97f1", cursor: "#50a4e9", num: "#f5983a" },
  doom_one: { bg: "#282c34", chrome: "#21242b", border: "#3f444a", fg: "#bbc2cf", muted: "#6d7580", kw: "#c678dd", cursor: "#51afef", num: "#da8548" },
  one_light: { bg: "#fafafa", chrome: "#f0f0f1", border: "#dcdfe4", fg: "#383a42", muted: "#787c8a", kw: "#a626a4", cursor: "#4078f2", num: "#986801" },
};

export function mountElixirPlayground(root: HTMLElement): void {
  const copy = readLabCopy(root);
  const themeSelect = root.querySelector<HTMLSelectElement>('[data-cfg-field="theme"]');
  const linesSelect = root.querySelector<HTMLSelectElement>('[data-cfg-field="lines"]');
  const goTabSelect = root.querySelector<HTMLSelectElement>('[data-cfg-field="goTab"]');
  const goFormatBox = root.querySelector<HTMLInputElement>('[data-cfg-field="goFormat"]');
  const codeEl = root.querySelector<HTMLElement>("#cfg-preview-code");
  const previewEl = root.querySelector<HTMLElement>("[data-theme-preview]");
  const themeNameEl = root.querySelector<HTMLElement>("[data-cfg-theme-name]");
  const statusEl = root.querySelector<HTMLElement>("[data-cfg-status]");
  const copyButton = root.querySelector<HTMLButtonElement>("[data-cfg-copy]");
  const lineNumberEls = Array.from(root.querySelectorAll<HTMLElement>("[data-tp-ln]"));
  const indentEls = Array.from(root.querySelectorAll<HTMLElement>("[data-tp-indent]"));

  // Read the controls, not the defaults: a browser may restore the reader's earlier choices when the page reloads.
  function readControls(): ConfigOptions {
    return parseConfig({
      theme: themeSelect?.value,
      lines: linesSelect?.value,
      goTab: goTabSelect?.value,
      goFormat: goFormatBox?.checked,
    });
  }

  function setStatus(textId: string | null): void {
    if (statusEl) statusEl.textContent = textId ? copy.text(textId) : "";
    root.classList.toggle("is-copied", textId === "copied");
  }

  let cfg = readControls();

  function render(): void {
    if (codeEl) renderElixirBlockDom(codeEl, generateConfigExs(cfg));

    if (previewEl) {
      const palette = THEME_PALETTES[cfg.theme];
      for (const [name, value] of Object.entries(palette)) {
        previewEl.style.setProperty(`--tp-${name}`, value);
      }
    }
    previewLineNumbers(cfg.lines).forEach((text, index) => {
      const el = lineNumberEls[index];
      if (el) el.textContent = text;
    });
    for (const el of indentEls) el.textContent = " ".repeat(cfg.goTab);

    // The theme name is the builder's one live region, so it is rewritten only when the theme changes.
    const themeName = themeSelect?.selectedOptions[0]?.textContent?.trim() ?? "";
    if (themeNameEl && themeNameEl.textContent !== themeName) themeNameEl.textContent = themeName;
  }

  root.addEventListener("change", (event) => {
    if (!(event.target instanceof Element) || !event.target.matches("[data-cfg-field]")) return;
    cfg = readControls();
    // The clipboard no longer holds what the page shows.
    setStatus(null);
    render();
  });

  copyButton?.addEventListener("click", () => {
    keepFocus(copyButton);
    const text = generateConfigExs(cfg);
    const written = navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject(new Error("no clipboard"));
    written.then(
      () => {
        setStatus("copied");
        completeMission("elixir", "copied");
      },
      () => setStatus("copy_failed"),
    );
  });

  render();
}
