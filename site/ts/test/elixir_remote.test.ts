import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  DEFAULT_CONFIG,
  ELIXIR_STEPS,
  GO_TAB_WIDTHS,
  LINE_NUMBER_MODES,
  MINGA_THEMES,
  SOURCE_EDITORS,
  THEME_PALETTES,
  TRANSLATOR_ROWS,
  TRANSLATOR_START,
  chooseEditor,
  generateConfigExs,
  hasTranslated,
  parseConfig,
  previewLineNumbers,
  selectRow,
  type TranslatorRow,
} from "../src/elixir_lab.ts";
import { LESSON_STEPS } from "../src/progress.ts";
import { evaluatePreToolUse } from "../src/remote_lab.ts";
import { readPageLab } from "./support/page_copy.ts";

const PAGE = "learn/elixir.html";

function text(html: string): string {
  return html
    .replace(/<[^>]*>/g, "")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&amp;", "&");
}

/** One translator row cut out of the page: its feature name, its explanation, and one snippet per `data-tr-src`. */
function pageRow(id: TranslatorRow): { feature: string; note: string; snippets: Record<string, string> } {
  const lab = readPageLab(PAGE, "data-elixir-translator").html;
  const start = lab.indexOf(`data-tr-row="${id}"`);
  assert.notEqual(start, -1, `the page has no translator row "${id}"`);
  const next = lab.indexOf("data-tr-row=", start + 1);
  const html = lab.slice(start, next === -1 ? lab.length : next);
  const snippets: Record<string, string> = {};
  for (const m of html.matchAll(/data-tr-src="([^"]+)">[\s\S]*?<pre><code>([\s\S]*?)<\/code><\/pre>/g)) {
    snippets[m[1]!] = text(m[2]!);
  }
  return {
    feature: text(/class="tr-feature">([\s\S]*?)<\/span>/.exec(html)?.[1] ?? ""),
    note: text(/class="tr-note"[^>]*>([\s\S]*?)<\/div>/.exec(html)?.[1] ?? "").trim(),
    snippets,
  };
}

/** What each row must show: one named feature, and the words that make each editor's snippet that feature and no other. */
const ROW_FEATURES: Record<TranslatorRow, { feature: string; lua: RegExp; elisp: RegExp; vscode: RegExp; minga: string }> = {
  theme: {
    feature: "Color theme",
    lua: /^vim\.cmd\.colorscheme\("catppuccin-latte"\)$/,
    elisp: /catppuccin-flavor 'latte\)\s+\(load-theme 'catppuccin :no-confirm\)/,
    vscode: /^"workbench\.colorTheme": "Catppuccin Latte"$/,
    minga: "set :theme, :catppuccin_latte",
  },
  filetype: {
    feature: "Tab width for one language",
    lua: /"FileType"[\s\S]*pattern = "go"[\s\S]*tabstop = 8[\s\S]*shiftwidth = 8/,
    elisp: /go-mode-hook[\s\S]*setq-local tab-width 8/,
    vscode: /"\[go\]"[\s\S]*"editor\.tabSize": 8/,
    minga: "for_filetype :go, tab_width: 8, indent_with: :tabs",
  },
  format: {
    feature: "Format on save",
    lua: /"BufWritePre"[\s\S]*pattern = "\*\.go"[\s\S]*vim\.lsp\.buf\.format\(\)/,
    elisp: /before-save-hook #'gofmt-before-save/,
    vscode: /"\[go\]"[\s\S]*"editor\.formatOnSave": true/,
    minga: "for_filetype :go, format_on_save: true",
  },
  key: {
    feature: "Your own key for Save",
    lua: /vim\.keymap\.set\("n", "<leader>fw", "<cmd>write<cr>"/,
    elisp: /global-set-key \(kbd "C-c w"\) #'save-buffer/,
    vscode: /^\[\s*\{\s*"key": "ctrl\+alt\+w",\s*"command": "workbench\.action\.files\.save"\s*\}\s*\]$/,
    minga: 'bind :normal, "SPC f w", :save, "Save file"',
  },
};

describe("Lesson 04 translator", () => {
  it("lists the same rows and editors in the page and in the script", () => {
    const lab = readPageLab(PAGE, "data-elixir-translator");
    assert.deepEqual(lab.attr("data-tr-row"), [...TRANSLATOR_ROWS]);
    assert.deepEqual(lab.attr("data-tr-editor"), [...SOURCE_EDITORS]);
  });

  for (const id of TRANSLATOR_ROWS) {
    it(`row "${id}" shows one feature as four snippets with an explanation`, () => {
      const row = pageRow(id);
      const want = ROW_FEATURES[id];
      assert.equal(row.feature, want.feature);
      assert.deepEqual(Object.keys(row.snippets), [...SOURCE_EDITORS, "minga"]);
      assert.match(row.snippets.lua!, want.lua);
      assert.match(row.snippets.elisp!, want.elisp);
      assert.match(row.snippets.vscode!, want.vscode);
      assert.equal(row.snippets.minga, want.minga);
      assert.ok(row.note.length > 80, "the row explains its Minga line");
    });

    it(`row "${id}" has a button that controls its own explanation`, () => {
      const lab = readPageLab(PAGE, "data-elixir-translator");
      assert.ok(lab.attr("aria-controls").includes(`tr-note-${id}`));
      assert.ok(lab.attr("id").includes(`tr-note-${id}`));
    });
  }

  it("counts a setting as translated only when an editor is chosen and a row is open", () => {
    assert.equal(hasTranslated(TRANSLATOR_START), false);
    assert.equal(hasTranslated(chooseEditor(TRANSLATOR_START, "elisp")), false);
    assert.equal(hasTranslated(selectRow(TRANSLATOR_START, "format")), false);
    assert.equal(hasTranslated(selectRow(chooseEditor(TRANSLATOR_START, "elisp"), "format")), true);
    assert.equal(hasTranslated(chooseEditor(selectRow(TRANSLATOR_START, "format"), "vscode")), true);
  });

  it("selecting the open row closes it and keeps the editor", () => {
    const open = selectRow(chooseEditor(TRANSLATOR_START, "lua"), "key");
    assert.deepEqual(selectRow(open, "key"), { editor: "lua", row: null });
    assert.deepEqual(selectRow(open, "theme"), { editor: "lua", row: "theme" });
  });
});

describe("Lesson 04 progress", () => {
  it("records exactly the ids the lesson list holds", () => {
    assert.deepEqual(LESSON_STEPS.elixir, ELIXIR_STEPS);
  });
});

describe("Lesson 04 config builder", () => {
  it("writes the default config: a theme, line numbers and one Go line that indents with tabs", () => {
    assert.equal(
      generateConfigExs(DEFAULT_CONFIG),
      ["use Minga.Config", "", "set :theme, :catppuccin_frappe", "set :line_numbers, :relative", "", "for_filetype :go, tab_width: 8, indent_with: :tabs, format_on_save: true"].join("\n"),
    );
  });

  it("writes each option the builder offers", () => {
    for (const theme of MINGA_THEMES) {
      assert.match(generateConfigExs({ ...DEFAULT_CONFIG, theme }), new RegExp(`^set :theme, :${theme}$`, "m"));
    }
    for (const lines of LINE_NUMBER_MODES) {
      assert.match(generateConfigExs({ ...DEFAULT_CONFIG, lines }), new RegExp(`^set :line_numbers, :${lines}$`, "m"));
    }
    for (const goTab of GO_TAB_WIDTHS) {
      assert.match(generateConfigExs({ ...DEFAULT_CONFIG, goTab, goFormat: false }), new RegExp(`^for_filetype :go, tab_width: ${goTab}, indent_with: :tabs$`, "m"));
    }
  });

  it("never writes a hook, an MCP server, an extension or a key binding", () => {
    for (const theme of MINGA_THEMES) {
      for (const lines of LINE_NUMBER_MODES) {
        for (const goTab of GO_TAB_WIDTHS) {
          for (const goFormat of [true, false]) {
            const out = generateConfigExs({ theme, lines, goTab, goFormat });
            assert.doesNotMatch(out, /agent_hooks|agent_mcp_servers|mcp_server|extension|\bon :|\bbind\b/);
            assert.equal(out.split("\n").length, 6);
          }
        }
      }
    }
  });

  it("does not offer :hybrid line numbers, which the macOS app replaces with :absolute when it starts", () => {
    assert.ok(!(LINE_NUMBER_MODES as readonly string[]).includes("hybrid"));
  });

  it("falls back to the default for a value the builder does not offer", () => {
    assert.deepEqual(parseConfig({ theme: "solarized", lines: "fancy", goTab: "3" }), DEFAULT_CONFIG);
    assert.deepEqual(parseConfig({ theme: "one_light", lines: "none", goTab: "2", goFormat: false }), {
      theme: "one_light",
      lines: "none",
      goTab: 2,
      goFormat: false,
    });
  });

  it("numbers the preview gutter the way each mode does around a cursor on line 15", () => {
    assert.deepEqual(previewLineNumbers("absolute"), ["14", "15", "16", "17"]);
    assert.deepEqual(previewLineNumbers("relative"), ["1", "0", "1", "2"]);
    assert.deepEqual(previewLineNumbers("none"), ["", "", "", ""]);
  });

  it("has a preview palette for every theme", () => {
    assert.deepEqual(Object.keys(THEME_PALETTES).sort(), [...MINGA_THEMES].sort());
  });

  it("offers in the page exactly the values the script accepts, with the defaults selected", () => {
    const lab = readPageLab(PAGE, "data-elixir-playground");
    assert.deepEqual(lab.attr("data-cfg-field"), ["theme", "lines", "goTab", "goFormat"]);
    assert.deepEqual(lab.attr("value"), [...MINGA_THEMES, ...LINE_NUMBER_MODES, ...GO_TAB_WIDTHS.map(String)]);
    const selected = Array.from(lab.html.matchAll(/<option value="([^"]+)" selected>/g), (m) => m[1]);
    assert.deepEqual(selected, [DEFAULT_CONFIG.theme, DEFAULT_CONFIG.lines, String(DEFAULT_CONFIG.goTab)]);
    assert.match(lab.html, /data-cfg-field="goFormat" checked>/);
  });

  it("shows the default config and preview in the page before the script runs", () => {
    const lab = readPageLab(PAGE, "data-elixir-playground");
    const code = /<code id="cfg-preview-code">([\s\S]*?)<\/code>/.exec(lab.html)?.[1] ?? "";
    assert.equal(text(code), generateConfigExs(DEFAULT_CONFIG));
    const gutter = Array.from(lab.html.matchAll(/data-tp-ln>([^<]*)</g), (m) => m[1]);
    assert.deepEqual(gutter, [...previewLineNumbers(DEFAULT_CONFIG.lines)]);
    const indents = Array.from(lab.html.matchAll(/data-tp-indent>([^<]*)</g), (m) => m[1]);
    assert.deepEqual(indents, [" ".repeat(DEFAULT_CONFIG.goTab), " ".repeat(DEFAULT_CONFIG.goTab)]);
  });

  it("holds in the page every element and string the script looks up", () => {
    const lab = readPageLab(PAGE, "data-elixir-playground");
    for (const hook of ["data-theme-preview", "data-cfg-theme-name", "data-cfg-status", "data-cfg-copy"]) {
      assert.match(lab.html, new RegExp(`\\s${hook}[\\s>]`), `the page has no ${hook}`);
    }
    assert.deepEqual(lab.texts, ["copied", "copy_failed"]);
    assert.match(lab.html, /data-cfg-theme-name aria-live="polite">Catppuccin Frappé</);
    assert.equal(lab.attr("aria-live").length, 1, "the theme name is the builder's only live region");
  });
});

describe("Lesson 05 PreToolUse veto evaluator", () => {
  it("blocks destructive shell commands with exit 1 and allows safe test commands with exit 0", () => {
    const veto = evaluatePreToolUse("git push --force origin main");
    assert.equal(veto.allowed, false);
    assert.equal(veto.exitCode, 1);
    assert.match(veto.stderr, /Blocked by local safety hook/);

    const safe = evaluatePreToolUse("mix test test/minga_agent/retry_test.exs");
    assert.equal(safe.allowed, true);
    assert.equal(safe.exitCode, 0);
    assert.equal(safe.stderr, "");
  });
});
