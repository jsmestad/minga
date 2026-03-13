defmodule Minga.Theme.OneDark do
  @moduledoc """
  One Dark theme, based on Atom's One Dark syntax theme.

  A dark theme with the classic Atom color palette.
  """

  # ── One Dark palette (Atom) ───────────────────────────────────────────
  @mono_1 0xABB2BF
  @mono_2 0x818896
  @mono_3 0x5C6370
  @hue_1 0x56B6C2
  @hue_2 0x61AFEF
  @hue_3 0xC678DD
  @hue_4 0x98C379
  @hue_5 0xE06C75
  @hue_6 0xD19A66
  @hue_6_2 0xE5C07B
  @syntax_bg 0x282C34
  @syntax_gutter 0x636D83
  @syntax_guide 0x3B4048
  @ui_bg 0x21252B
  @ui_fg 0x9DA5B4

  @doc "Returns the One Dark theme struct."
  @spec theme() :: Minga.Theme.t()
  def theme do
    %Minga.Theme{
      name: :one_dark,
      syntax: syntax(),
      editor: %Minga.Theme.Editor{
        bg: @syntax_bg,
        fg: @mono_1,
        tilde_fg: @syntax_gutter,
        split_border_fg: @syntax_guide
      },
      gutter: %Minga.Theme.Gutter{
        fg: @syntax_gutter,
        current_fg: @mono_1,
        error_fg: @hue_5,
        warning_fg: @hue_6_2,
        info_fg: @hue_2,
        hint_fg: @syntax_gutter
      },
      git: %Minga.Theme.Git{
        added_fg: @hue_4,
        modified_fg: @hue_2,
        deleted_fg: @hue_5
      },
      modeline: %Minga.Theme.Modeline{
        bar_fg: @ui_fg,
        bar_bg: @ui_bg,
        info_fg: @ui_fg,
        info_bg: @syntax_guide,
        filetype_fg: @hue_4,
        mode_colors: %{
          normal: {0x000000, @hue_2},
          insert: {0x000000, @hue_4},
          visual: {0x000000, @hue_3},
          operator_pending: {0x000000, @hue_6},
          command: {0x000000, @hue_6_2},
          replace: {0x000000, @hue_5},
          search: {0x000000, @hue_1}
        }
      },
      picker: %Minga.Theme.Picker{
        bg: @ui_bg,
        sel_bg: @syntax_guide,
        prompt_bg: @ui_bg,
        dim_fg: @mono_3,
        text_fg: @mono_1,
        highlight_fg: 0xFFFFFF,
        match_fg: @hue_6_2,
        border_fg: @hue_2,
        menu_bg: @syntax_bg,
        menu_fg: @mono_1,
        menu_sel_bg: @syntax_guide,
        menu_sel_fg: 0xFFFFFF
      },
      minibuffer: %Minga.Theme.Minibuffer{
        fg: @mono_1,
        bg: 0x000000,
        warning_fg: @hue_6_2,
        dim_fg: @mono_3
      },
      search: %Minga.Theme.Search{
        highlight_fg: 0x000000,
        highlight_bg: @hue_6_2,
        current_bg: @hue_5
      },
      popup: %Minga.Theme.Popup{
        fg: @mono_1,
        bg: @syntax_guide,
        border_fg: @mono_2,
        sel_fg: @syntax_bg,
        sel_bg: @hue_2,
        title_fg: @hue_2,
        key_fg: @hue_1,
        separator_fg: @mono_3,
        group_fg: @hue_2
      },
      tree: %Minga.Theme.Tree{
        bg: 0x21252B,
        fg: @mono_1,
        dir_fg: @hue_2,
        active_fg: @hue_4,
        cursor_bg: @syntax_guide,
        header_fg: @hue_2,
        header_bg: 0x21252B,
        separator_fg: @syntax_gutter,
        modified_fg: @hue_6,
        git_modified_fg: @hue_6,
        git_staged_fg: @hue_4,
        git_untracked_fg: @mono_3,
        git_conflict_fg: @hue_5
      },
      agent: %Minga.Theme.Agent{
        panel_bg: @syntax_bg,
        panel_border: @syntax_guide,
        header_fg: @hue_2,
        header_bg: @ui_bg,
        user_border: @hue_2,
        user_label: @hue_2,
        assistant_border: @hue_4,
        assistant_label: @hue_4,
        tool_border: @hue_6_2,
        tool_header: @hue_6_2,
        code_bg: @ui_bg,
        code_border: @syntax_guide,
        input_border: @hue_2,
        input_bg: @ui_bg,
        input_placeholder: @mono_3,
        thinking_fg: @hue_6_2,
        status_thinking: @hue_6_2,
        status_tool: @hue_1,
        status_error: @hue_5,
        status_idle: @mono_3,
        text_fg: @mono_1,
        context_low: @hue_4,
        context_mid: @hue_6_2,
        context_high: @hue_5,
        usage_fg: @mono_3,
        toast_bg: @syntax_guide,
        toast_fg: @mono_1,
        toast_border: @mono_2,
        system_fg: @mono_2,
        search_match_bg: @hue_6_2,
        search_current_bg: @hue_5,
        hint_fg: 0x5C6370,
        heading1_fg: @hue_3,
        heading2_fg: @hue_2,
        heading3_fg: @hue_4,
        dashboard_label: 0x61AFEF
      },
      tab_bar: %Minga.Theme.TabBar{
        active_fg: @ui_fg,
        active_bg: @syntax_bg,
        inactive_fg: @syntax_guide,
        inactive_bg: @ui_bg,
        separator_fg: @syntax_guide,
        modified_fg: @hue_6_2,
        attention_fg: @hue_5,
        bg: @ui_bg
      }
    }
  end

  @spec syntax() :: Minga.Theme.syntax()
  defp syntax do
    %{
      # ── Keywords ────────────────────────────────────────────────────────
      "keyword" => [fg: @hue_3, bold: true],
      "keyword.function" => [fg: @hue_3, bold: true],
      "keyword.operator" => [fg: @hue_3],
      "keyword.return" => [fg: @hue_3, bold: true],
      "keyword.conditional" => [fg: @hue_3, bold: true],
      "keyword.coroutine" => [fg: @hue_3, bold: true],
      "keyword.directive" => [fg: @hue_3],
      "keyword.exception" => [fg: @hue_3],
      "keyword.import" => [fg: @hue_3],
      "keyword.modifier" => [fg: @hue_3, bold: true],
      "keyword.repeat" => [fg: @hue_3, bold: true],
      "keyword.type" => [fg: @hue_3, bold: true],
      "conditional" => [fg: @hue_3, bold: true],
      "exception" => [fg: @hue_3],
      "include" => [fg: @hue_3],
      "import" => [fg: @hue_3],
      "repeat" => [fg: @hue_3, bold: true],

      # ── Strings ─────────────────────────────────────────────────────────
      "string" => [fg: @hue_4],
      "string.special" => [fg: @hue_6],
      "string.special.symbol" => [fg: @hue_1],
      "string.special.key" => [fg: @hue_2],
      "string.special.regex" => [fg: @hue_6],
      "string.escape" => [fg: @hue_1],
      "string.regex" => [fg: @hue_6],
      "character" => [fg: @hue_6],

      # ── Comments ────────────────────────────────────────────────────────
      "comment" => [fg: @mono_3, italic: true],
      "comment.doc" => [fg: @mono_2, italic: true],
      "comment.documentation" => [fg: @mono_2, italic: true],
      "comment.unused" => [fg: @mono_3, italic: true],
      "comment.discard" => [fg: @mono_3, italic: true],

      # ── Functions ───────────────────────────────────────────────────────
      "function" => [fg: @hue_2],
      "function.call" => [fg: @hue_2],
      "function.builtin" => [fg: @hue_1],
      "function.macro" => [fg: @hue_3, bold: true],
      "function.method" => [fg: @hue_2],
      "function.method.builtin" => [fg: @hue_1],
      "function.special" => [fg: @hue_3],
      "method" => [fg: @hue_2],
      "method.call" => [fg: @hue_2],

      # ── Types ───────────────────────────────────────────────────────────
      "type" => [fg: @hue_6_2],
      "type.builtin" => [fg: @hue_6_2, bold: true],

      # ── Variables ───────────────────────────────────────────────────────
      "variable" => [fg: @mono_1],
      "variable.builtin" => [fg: @hue_6],
      "variable.parameter" => [fg: @hue_5],
      "variable.member" => [fg: @hue_1],
      "parameter" => [fg: @hue_5],
      "field" => [fg: @hue_1],

      # ── Constants & numbers ─────────────────────────────────────────────
      "constant" => [fg: @hue_6],
      "constant.builtin" => [fg: @hue_6, bold: true],
      "boolean" => [fg: @hue_6, bold: true],
      "number" => [fg: @hue_6],
      "number.float" => [fg: @hue_6],
      "float" => [fg: @hue_6],

      # ── Operators & punctuation ─────────────────────────────────────────
      "operator" => [fg: @hue_1],
      "punctuation" => [fg: @mono_3],
      "punctuation.bracket" => [fg: @mono_1],
      "punctuation.delimiter" => [fg: @mono_1],
      "punctuation.special" => [fg: @hue_5],
      "delimiter" => [fg: @mono_1],

      # ── Modules & namespaces ────────────────────────────────────────────
      "module" => [fg: @hue_6_2],
      "namespace" => [fg: @hue_6_2],

      # ── Attributes & properties ─────────────────────────────────────────
      "attribute" => [fg: @hue_6],
      "property" => [fg: @hue_1],
      "label" => [fg: @hue_5],

      # ── Tags (HTML/XML) ────────────────────────────────────────────────
      "tag" => [fg: @hue_5],
      "tag.attribute" => [fg: @hue_6],
      "tag.error" => [fg: @hue_5, bold: true],

      # ── Preprocessor ───────────────────────────────────────────────────
      "preproc" => [fg: @hue_3, bold: true],

      # ── Text / markup ──────────────────────────────────────────────────
      "text.title" => [fg: @hue_5, bold: true],
      "text.strong" => [fg: @hue_6, bold: true],
      "text.emphasis" => [fg: @hue_3, italic: true],
      "text.literal" => [fg: @hue_4],
      "text.uri" => [fg: @hue_1, underline: true],
      "text.reference" => [fg: @hue_2],

      # ── CSS-specific ───────────────────────────────────────────────────
      "charset" => [fg: @hue_3, bold: true],
      "keyframes" => [fg: @hue_3, bold: true],
      "media" => [fg: @hue_3, bold: true],
      "supports" => [fg: @hue_3, bold: true],

      # ── Misc ───────────────────────────────────────────────────────────
      "escape" => [fg: @hue_1],
      "embedded" => [fg: @mono_1],
      "constructor" => [fg: @hue_6_2, bold: true],
      "error" => [fg: @hue_5, bold: true],
      "warning" => [fg: @hue_6_2, bold: true]
    }
  end
end
