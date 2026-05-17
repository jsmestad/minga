defmodule MingaEditor.UI.Theme.Catppuccin do
  @moduledoc """
  Shared palette and theme builder for the Catppuccin theme family.

  Catppuccin is a community-driven pastel theme with four flavors:
  Latte (light), Frappe, Macchiato, and Mocha (darkest).
  Palette values sourced from https://github.com/catppuccin/catppuccin.
  """

  alias Minga.Core.Face
  alias MingaEditor.UI.Theme.Builder
  alias MingaEditor.UI.Theme.Palette

  @doc "Builds a full `MingaEditor.UI.Theme.t()` struct from a Catppuccin palette map."
  @spec build(atom(), map()) :: MingaEditor.UI.Theme.t()
  def build(name, p) do
    Builder.from_palette(name, palette(name, p), overrides(p))
  end

  @spec palette(atom(), map()) :: Palette.t()
  defp palette(name, p) do
    Palette.new(%{
      variant: variant(name),
      bg: p.base,
      fg: p.text,
      surface: p.surface0,
      overlay: p.mantle,
      muted: p.overlay0,
      subtle: p.surface1,
      accent: p.blue,
      highlight: p.blue,
      selection_bg: p.surface2,
      error: p.red,
      warning: p.yellow,
      info: p.blue,
      success: p.green,
      match: p.yellow,
      link: p.rosewater,
      border: p.overlay1,
      contrast_fg: p.base,
      builtin: p.teal,
      functions: p.blue,
      keywords: p.mauve,
      methods: p.blue,
      operators: p.sky,
      constants: p.peach,
      strings: p.green,
      numbers: p.peach,
      type: p.yellow,
      variables: p.text,
      comments: p.overlay0
    })
  end

  @spec variant(atom()) :: Palette.variant()
  defp variant(:catppuccin_latte), do: :light
  defp variant(_name), do: :dark

  @spec overrides(map()) :: map()
  defp overrides(p) do
    %{
      syntax: syntax(p),
      hl_todo: %{
        todo: Face.new(fg: p.yellow, bold: true),
        fixme: Face.new(fg: p.red, bold: true),
        note: Face.new(fg: p.blue, bold: true),
        hack: Face.new(fg: p.peach, bold: true),
        review: Face.new(fg: p.mauve, bold: true),
        deprecated: Face.new(fg: p.overlay0, strikethrough: true)
      },
      editor: %{
        bg: p.base,
        fg: p.text,
        tilde_fg: p.surface1,
        split_border_fg: p.surface1,
        cursorline_bg: p.surface0,
        nav_flash_bg: p.surface1,
        yank_flash_bg: p.surface1,
        highlight_read_bg: p.surface1,
        highlight_write_bg: p.surface2,
        selection_bg: p.surface2,
        whitespace_fg: p.overlay0,
        indent_guide_fg: p.surface1,
        indent_guide_active_fg: p.overlay0
      },
      gutter: %{
        fg: p.overlay0,
        current_fg: p.text,
        error_fg: p.red,
        warning_fg: p.yellow,
        info_fg: p.blue,
        hint_fg: p.overlay0,
        fold_fg: p.overlay0,
        separator_fg: p.overlay0
      },
      git: %{added_fg: p.green, modified_fg: p.blue, deleted_fg: p.red},
      modeline: %{
        bar_fg: p.text,
        bar_bg: p.mantle,
        info_fg: p.text,
        info_bg: p.surface0,
        filetype_fg: p.green,
        mode_colors: %{
          normal: {p.base, p.blue},
          insert: {p.base, p.green},
          visual: {p.base, p.mauve},
          operator_pending: {p.base, p.peach},
          command: {p.base, p.yellow},
          replace: {p.base, p.red},
          search: {p.base, p.sky}
        },
        lsp_ready: p.green,
        lsp_initializing: p.yellow,
        lsp_starting: p.overlay0,
        lsp_error: p.red
      },
      picker: %{
        bg: p.mantle,
        sel_bg: p.surface1,
        prompt_bg: p.mantle,
        dim_fg: p.overlay0,
        text_fg: p.text,
        highlight_fg: p.lavender,
        match_fg: p.yellow,
        border_fg: p.blue,
        menu_bg: p.base,
        menu_fg: p.text,
        menu_sel_bg: p.surface1,
        menu_sel_fg: p.lavender
      },
      minibuffer: %{fg: p.text, bg: p.crust, warning_fg: p.yellow, dim_fg: p.overlay0},
      search: %{highlight_fg: p.base, highlight_bg: p.yellow, current_bg: p.red},
      popup: %{
        fg: p.text,
        bg: p.surface0,
        border_fg: p.overlay1,
        sel_fg: p.base,
        sel_bg: p.blue,
        title_fg: p.blue,
        key_fg: p.teal,
        separator_fg: p.overlay0,
        group_fg: p.blue
      },
      tree: %{
        bg: p.mantle,
        fg: p.text,
        dir_fg: p.blue,
        active_fg: p.green,
        cursor_bg: p.surface0,
        header_fg: p.blue,
        header_bg: p.mantle,
        separator_fg: p.surface1,
        modified_fg: p.peach,
        git_modified_fg: p.peach,
        git_staged_fg: p.green,
        git_untracked_fg: p.overlay0,
        git_conflict_fg: p.red
      },
      agent: %{
        panel_bg: p.base,
        panel_border: p.surface1,
        header_fg: p.blue,
        header_bg: p.mantle,
        user_border: p.blue,
        user_label: p.blue,
        assistant_border: p.green,
        assistant_label: p.green,
        tool_border: p.yellow,
        tool_header: p.yellow,
        code_bg: p.mantle,
        code_border: p.surface1,
        input_border: p.blue,
        input_bg: p.base,
        input_placeholder: p.overlay0,
        thinking_fg: p.yellow,
        status_thinking: p.yellow,
        status_tool: p.sky,
        status_error: p.red,
        status_idle: p.overlay0,
        text_fg: p.text,
        context_low: p.green,
        context_mid: p.yellow,
        context_high: p.red,
        usage_fg: p.overlay0,
        toast_bg: p.surface0,
        toast_fg: p.text,
        toast_border: p.overlay1,
        system_fg: p.overlay1,
        search_match_bg: p.yellow,
        search_current_bg: p.red,
        hint_fg: p.overlay0,
        heading1_fg: p.mauve,
        heading2_fg: p.blue,
        heading3_fg: p.green,
        dashboard_label: p.blue,
        delimiter_dim: p.surface0,
        link_fg: p.blue
      },
      dashboard: %{
        bg: p.base,
        logo_fg: p.yellow,
        heading_fg: p.blue,
        item_fg: p.text,
        item_active_bg: p.surface0,
        shortcut_fg: p.green,
        muted_fg: p.overlay0
      },
      tab_bar: %{
        active_fg: p.text,
        active_bg: p.base,
        inactive_fg: p.overlay0,
        inactive_bg: p.mantle,
        separator_fg: p.surface0,
        modified_fg: p.peach,
        attention_fg: p.red,
        close_hover_fg: p.red,
        bg: p.mantle
      }
    }
  end

  @spec syntax(map()) :: MingaEditor.UI.Theme.syntax()
  defp syntax(p) do
    %{
      # ── Keywords ────────────────────────────────────────────────────────
      "keyword" => [fg: p.mauve, bold: true],
      "keyword.function" => [fg: p.mauve, bold: true],
      "keyword.operator" => [fg: p.mauve],
      "keyword.return" => [fg: p.mauve, bold: true],
      "keyword.conditional" => [fg: p.mauve, bold: true],
      "keyword.coroutine" => [fg: p.mauve, bold: true],
      "keyword.directive" => [fg: p.mauve],
      "keyword.exception" => [fg: p.mauve],
      "keyword.import" => [fg: p.mauve],
      "keyword.modifier" => [fg: p.mauve, bold: true],
      "keyword.repeat" => [fg: p.mauve, bold: true],
      "keyword.type" => [fg: p.mauve, bold: true],
      "conditional" => [fg: p.mauve, bold: true],
      "exception" => [fg: p.mauve],
      "include" => [fg: p.mauve],
      "import" => [fg: p.mauve],
      "repeat" => [fg: p.mauve, bold: true],

      # ── Strings ─────────────────────────────────────────────────────────
      "string" => [fg: p.green],
      "string.special" => [fg: p.peach],
      "string.special.symbol" => [fg: p.flamingo],
      "string.special.key" => [fg: p.blue],
      "string.special.regex" => [fg: p.peach],
      "string.escape" => [fg: p.pink],
      "string.regex" => [fg: p.peach],
      "character" => [fg: p.teal],

      # ── Comments ────────────────────────────────────────────────────────
      "comment" => [fg: p.overlay0, italic: true],
      "comment.doc" => [fg: p.overlay1, italic: true],
      "comment.documentation" => [fg: p.overlay1, italic: true],
      "comment.unused" => [fg: p.overlay0, italic: true],
      "comment.discard" => [fg: p.overlay0, italic: true],

      # ── Functions ───────────────────────────────────────────────────────
      "function" => [fg: p.blue],
      "function.call" => [fg: p.blue],
      "function.builtin" => [fg: p.teal],
      "function.macro" => [fg: p.mauve, bold: true],
      "function.method" => [fg: p.blue],
      "function.method.builtin" => [fg: p.teal],
      "function.special" => [fg: p.mauve],
      "method" => [fg: p.blue],
      "method.call" => [fg: p.blue],

      # ── Types ───────────────────────────────────────────────────────────
      "type" => [fg: p.yellow],
      "type.builtin" => [fg: p.yellow, bold: true],

      # ── Variables ───────────────────────────────────────────────────────
      "variable" => [fg: p.text],
      "variable.builtin" => [fg: p.red],
      "variable.parameter" => [fg: p.maroon],
      "variable.member" => [fg: p.teal],
      "parameter" => [fg: p.maroon],
      "field" => [fg: p.teal],

      # ── Constants & numbers ─────────────────────────────────────────────
      "constant" => [fg: p.peach],
      "constant.builtin" => [fg: p.peach, bold: true],
      "boolean" => [fg: p.peach, bold: true],
      "number" => [fg: p.peach],
      "number.float" => [fg: p.peach],
      "float" => [fg: p.peach],

      # ── Operators & punctuation ─────────────────────────────────────────
      "operator" => [fg: p.sky],
      "punctuation" => [fg: p.overlay2],
      "punctuation.bracket" => [fg: p.overlay2],
      "punctuation.delimiter" => [fg: p.overlay2],
      "punctuation.special" => [fg: p.sky],
      "delimiter" => [fg: p.overlay2],

      # ── Modules & namespaces ────────────────────────────────────────────
      "module" => [fg: p.yellow],
      "namespace" => [fg: p.yellow],

      # ── Attributes & properties ─────────────────────────────────────────
      "attribute" => [fg: p.teal],
      "property" => [fg: p.teal],
      "label" => [fg: p.sapphire],

      # ── Tags (HTML/XML) ────────────────────────────────────────────────
      "tag" => [fg: p.mauve],
      "tag.attribute" => [fg: p.yellow],
      "tag.error" => [fg: p.red, bold: true],

      # ── Preprocessor ───────────────────────────────────────────────────
      "preproc" => [fg: p.pink, bold: true],

      # ── Markup (nvim-treesitter / tree-sitter standard) ────────────────
      "markup.heading" => [fg: p.red, bold: true],
      "markup.heading.1" => [fg: p.red, bold: true],
      "markup.heading.2" => [fg: p.peach, bold: true],
      "markup.heading.3" => [fg: p.yellow, bold: true],
      "markup.heading.4" => [fg: p.green, bold: true],
      "markup.heading.5" => [fg: p.blue, bold: true],
      "markup.heading.6" => [fg: p.mauve, bold: true],
      "markup.bold" => [fg: p.peach, bold: true],
      "markup.strong" => [fg: p.peach, bold: true],
      "markup.italic" => [fg: p.maroon, italic: true],
      "markup.strikethrough" => [fg: p.overlay0, strikethrough: true],
      "markup.raw" => [fg: p.green],
      "markup.raw.block" => [fg: p.green],
      "markup.raw.inline" => [fg: p.green],
      "markup.link" => [fg: p.rosewater],
      "markup.link.url" => [fg: p.rosewater, underline: true],
      "markup.link.label" => [fg: p.blue],
      "markup.list" => [fg: p.red],
      "markup.list.numbered" => [fg: p.red],
      "markup.list.unnumbered" => [fg: p.red],
      "markup.list.checked" => [fg: p.green],
      "markup.list.unchecked" => [fg: p.overlay0],
      "markup.quote" => [fg: p.overlay1, italic: true],

      # ── CSS-specific ───────────────────────────────────────────────────
      "charset" => [fg: p.mauve, bold: true],
      "keyframes" => [fg: p.mauve, bold: true],
      "media" => [fg: p.mauve, bold: true],
      "supports" => [fg: p.mauve, bold: true],

      # ── Misc ───────────────────────────────────────────────────────────
      "escape" => [fg: p.pink],
      "embedded" => [fg: p.text],
      "constructor" => [fg: p.sapphire, bold: true],
      "error" => [fg: p.red, bold: true],
      "warning" => [fg: p.yellow, bold: true]
    }
  end
end
