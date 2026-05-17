defmodule MingaEditor.UI.Theme.DoomOne do
  @moduledoc """
  Doom One theme, sourced from doomemacs/themes doom-one-theme.el.

  A dark theme with vibrant accent colors on a muted background. This is
  Minga's default theme.
  """

  # ── Doom One palette ──────────────────────────────────────────────────
  @blue 0x51AFEF
  @dark_blue 0x2257A0
  @red 0xFF6C6B
  @magenta 0xC678DD
  @variable_magenta 0xDCAEEA
  @green 0x98BE65
  @orange 0xDA8548
  @yellow 0xECBE7B
  @cyan 0x46D9FF
  @dark_cyan 0x5699AF
  @teal 0x4DB5BD
  @violet 0xA9A1E1
  @fg 0xBBC2CF
  @grey 0x3F444A
  @light_grey 0x818990
  @bg 0x282C34
  @bg_alt 0x21242B
  @base3 0x23272E
  @base4 0x3F444A
  @base5 0x5B6268
  @base6 0x73797E
  @base8 0xDFDFDF

  @doc "Returns the Doom One theme struct."
  @spec theme() :: MingaEditor.UI.Theme.t()
  def theme do
    %MingaEditor.UI.Theme{
      name: :doom_one,
      syntax: syntax(),
      hl_todo: %{
        todo: Minga.Core.Face.new(fg: @yellow, bold: true),
        fixme: Minga.Core.Face.new(fg: @red, bold: true),
        note: Minga.Core.Face.new(fg: @blue, bold: true),
        hack: Minga.Core.Face.new(fg: @orange, bold: true),
        review: Minga.Core.Face.new(fg: @magenta, bold: true),
        deprecated: Minga.Core.Face.new(fg: @grey, strikethrough: true)
      },
      editor: %MingaEditor.UI.Theme.Editor{
        bg: @bg,
        fg: @fg,
        tilde_fg: @base5,
        split_border_fg: @base5,
        cursorline_bg: 0x2C323C,
        nav_flash_bg: 0x3E4451,
        yank_flash_bg: 0x4B5263,
        highlight_read_bg: 0x3A3F4B,
        highlight_write_bg: 0x4A3F2B,
        selection_bg: 0x264F78,
        whitespace_fg: @base5,
        indent_guide_fg: 0x3B3F4C,
        indent_guide_active_fg: 0x5C6370
      },
      gutter: %MingaEditor.UI.Theme.Gutter{
        fg: @base5,
        current_fg: @fg,
        error_fg: @red,
        warning_fg: @yellow,
        info_fg: @blue,
        hint_fg: @base5,
        fold_fg: @base5,
        separator_fg: @base5
      },
      git: %MingaEditor.UI.Theme.Git{
        added_fg: @green,
        modified_fg: @orange,
        deleted_fg: @red
      },
      modeline: %MingaEditor.UI.Theme.Modeline{
        bar_fg: @fg,
        bar_bg: @base3,
        info_fg: @fg,
        info_bg: @base4,
        filetype_fg: @green,
        mode_colors: %{
          normal: {0x000000, @blue},
          insert: {0x000000, @green},
          visual: {0x000000, @magenta},
          operator_pending: {0x000000, @orange},
          command: {0x000000, @yellow},
          replace: {0x000000, @red},
          search: {0x000000, @cyan}
        },
        lsp_ready: @green,
        lsp_initializing: @yellow,
        lsp_starting: @base5,
        lsp_error: @red
      },
      picker: %MingaEditor.UI.Theme.Picker{
        bg: 0x1E2127,
        sel_bg: 0x3E4451,
        prompt_bg: 0x1E2127,
        dim_fg: 0x5C6370,
        text_fg: 0xABB2BF,
        highlight_fg: 0xFFFFFF,
        match_fg: 0xE5C07B,
        border_fg: 0x61AFEF,
        menu_bg: @bg,
        menu_fg: 0xABB2BF,
        menu_sel_bg: 0x3E4451,
        menu_sel_fg: 0xFFFFFF
      },
      minibuffer: %MingaEditor.UI.Theme.Minibuffer{
        fg: @base8,
        bg: 0x000000,
        warning_fg: 0xFFCC00,
        dim_fg: @base6
      },
      search: %MingaEditor.UI.Theme.Search{
        highlight_fg: 0x000000,
        highlight_bg: @yellow,
        current_bg: @red
      },
      popup: %MingaEditor.UI.Theme.Popup{
        fg: @base8,
        bg: @bg_alt,
        border_fg: @base6,
        sel_fg: @bg,
        sel_bg: @dark_blue,
        title_fg: @blue,
        key_fg: @cyan,
        separator_fg: @base5,
        group_fg: @blue
      },
      tree: %MingaEditor.UI.Theme.Tree{
        bg: @base3,
        fg: @fg,
        dir_fg: @fg,
        active_fg: @green,
        cursor_bg: 0x3E4451,
        header_fg: @blue,
        header_bg: @base3,
        separator_fg: @base5,
        modified_fg: @orange,
        git_modified_fg: @violet,
        git_staged_fg: @green,
        git_untracked_fg: @grey,
        git_conflict_fg: @red
      },
      agent: %MingaEditor.UI.Theme.Agent{
        panel_bg: @bg,
        panel_border: @base5,
        header_fg: @blue,
        header_bg: 0x1E2127,
        user_border: @blue,
        user_label: @blue,
        assistant_border: @green,
        assistant_label: @green,
        tool_border: @yellow,
        tool_header: @yellow,
        code_bg: 0x1E2127,
        code_border: @base5,
        input_border: @blue,
        input_bg: @bg,
        input_placeholder: @base5,
        thinking_fg: @yellow,
        status_thinking: @yellow,
        status_tool: @cyan,
        status_error: @red,
        status_idle: @base5,
        text_fg: @fg,
        context_low: @green,
        context_mid: @yellow,
        context_high: @red,
        usage_fg: @grey,
        toast_bg: @base4,
        toast_fg: @fg,
        toast_border: @base6,
        system_fg: @base6,
        search_match_bg: @yellow,
        search_current_bg: @red,
        hint_fg: 0x5C6370,
        heading1_fg: @magenta,
        heading2_fg: @blue,
        heading3_fg: @green,
        dashboard_label: 0x61AFEF,
        delimiter_dim: 0x3E4452,
        link_fg: 0x61AFEF
      },
      dashboard: %MingaEditor.UI.Theme.Dashboard{
        bg: @bg,
        logo_fg: @yellow,
        heading_fg: @blue,
        item_fg: @fg,
        item_active_bg: 0x3E4451,
        shortcut_fg: @green,
        muted_fg: @base5
      },
      tab_bar: %MingaEditor.UI.Theme.TabBar{
        active_fg: @fg,
        active_bg: @bg,
        inactive_fg: @base5,
        inactive_bg: @base3,
        separator_fg: 0x3F444A,
        modified_fg: @orange,
        attention_fg: @red,
        close_hover_fg: @red,
        bg: @base3
      }
    }
  end

  @spec syntax() :: MingaEditor.UI.Theme.syntax()
  defp syntax do
    %{
      # ── Keywords ────────────────────────────────────────────────────────
      "keyword" => [fg: @blue, bold: true],
      "keyword.function" => [fg: @blue, bold: true],
      "keyword.operator" => [fg: @blue],
      "keyword.return" => [fg: @blue, bold: true],
      "keyword.conditional" => [fg: @blue, bold: true],
      "keyword.coroutine" => [fg: @blue, bold: true],
      "keyword.directive" => [fg: @blue],
      "keyword.exception" => [fg: @blue],
      "keyword.import" => [fg: @blue],
      "keyword.modifier" => [fg: @blue, bold: true],
      "keyword.repeat" => [fg: @blue, bold: true],
      "keyword.type" => [fg: @blue, bold: true],
      "conditional" => [fg: @blue, bold: true],
      "exception" => [fg: @blue],
      "include" => [fg: @blue],
      "import" => [fg: @blue],
      "repeat" => [fg: @blue, bold: true],

      # ── Strings ─────────────────────────────────────────────────────────
      "string" => [fg: @green],
      "string.special" => [fg: @orange],
      "string.special.symbol" => [fg: @violet],
      "string.special.key" => [fg: @blue],
      "string.special.regex" => [fg: @orange],
      "string.escape" => [fg: @orange],
      "string.regex" => [fg: @orange],
      "character" => [fg: @orange],

      # ── Comments ────────────────────────────────────────────────────────
      "comment" => [fg: @grey, italic: true],
      "comment.doc" => [fg: @light_grey, italic: true],
      "comment.documentation" => [fg: @light_grey, italic: true],
      "comment.unused" => [fg: @grey, italic: true],
      "comment.discard" => [fg: @grey, italic: true],

      # ── Functions ───────────────────────────────────────────────────────
      "function" => [fg: @magenta],
      "function.call" => [fg: @magenta, italic: true],
      "function.builtin" => [fg: @magenta],
      "function.macro" => [fg: @magenta, bold: true],
      "function.method" => [fg: @cyan],
      "function.method.builtin" => [fg: @cyan],
      "function.special" => [fg: @dark_cyan],
      "method" => [fg: @cyan],
      "method.call" => [fg: @cyan],

      # ── Types ───────────────────────────────────────────────────────────
      "type" => [fg: @yellow],
      "type.builtin" => [fg: @yellow, bold: true],

      # ── Variables ───────────────────────────────────────────────────────
      "variable" => [fg: @variable_magenta],
      "variable.builtin" => [fg: @magenta],
      "variable.parameter" => [fg: @red],
      "variable.member" => [fg: @teal],
      "parameter" => [fg: @red],
      "field" => [fg: @teal],

      # ── Constants & numbers ─────────────────────────────────────────────
      "constant" => [fg: @violet],
      "constant.builtin" => [fg: @violet, bold: true],
      "boolean" => [fg: @violet, bold: true],
      "number" => [fg: @orange],
      "number.float" => [fg: @orange],
      "float" => [fg: @orange],

      # ── Operators & punctuation ─────────────────────────────────────────
      "operator" => [fg: @blue],
      "punctuation" => [fg: @grey],
      "punctuation.bracket" => [fg: @fg],
      "punctuation.delimiter" => [fg: @fg],
      "punctuation.special" => [fg: @red],
      "delimiter" => [fg: @fg],

      # ── Modules & namespaces ────────────────────────────────────────────
      "module" => [fg: @yellow],
      "namespace" => [fg: @yellow],

      # ── Attributes & properties ─────────────────────────────────────────
      "attribute" => [fg: @teal],
      "property" => [fg: @teal],
      "label" => [fg: @red],

      # ── Tags (HTML/XML) ────────────────────────────────────────────────
      "tag" => [fg: @magenta],
      "tag.attribute" => [fg: @yellow],
      "tag.error" => [fg: @red, bold: true],

      # ── Preprocessor ───────────────────────────────────────────────────
      "preproc" => [fg: @magenta, bold: true],

      # ── Markup (nvim-treesitter / tree-sitter standard) ────────────────
      "markup.heading" => [fg: @red, bold: true],
      "markup.heading.1" => [fg: @magenta, bold: true],
      "markup.heading.2" => [fg: @blue, bold: true],
      "markup.heading.3" => [fg: @green, bold: true],
      "markup.heading.4" => [fg: @yellow, bold: true],
      "markup.heading.5" => [fg: @cyan, bold: true],
      "markup.heading.6" => [fg: @orange, bold: true],
      "markup.bold" => [fg: @orange, bold: true],
      "markup.strong" => [fg: @orange, bold: true],
      "markup.italic" => [fg: @magenta, italic: true],
      "markup.strikethrough" => [fg: @grey, strikethrough: true],
      "markup.raw" => [fg: @green],
      "markup.raw.block" => [fg: @green],
      "markup.raw.inline" => [fg: @green],
      "markup.link" => [fg: @cyan],
      "markup.link.url" => [fg: @cyan, underline: true],
      "markup.link.label" => [fg: @blue],
      "markup.list" => [fg: @red],
      "markup.list.numbered" => [fg: @red],
      "markup.list.unnumbered" => [fg: @red],
      "markup.list.checked" => [fg: @green],
      "markup.list.unchecked" => [fg: @grey],
      "markup.quote" => [fg: @grey, italic: true],

      # ── CSS-specific ───────────────────────────────────────────────────
      "charset" => [fg: @blue, bold: true],
      "keyframes" => [fg: @blue, bold: true],
      "media" => [fg: @blue, bold: true],
      "supports" => [fg: @blue, bold: true],

      # ── Misc ───────────────────────────────────────────────────────────
      "escape" => [fg: @orange],
      "embedded" => [fg: @fg],
      "constructor" => [fg: @yellow, bold: true],
      "error" => [fg: @red, bold: true],
      "warning" => [fg: @yellow, bold: true]
    }
  end
end
