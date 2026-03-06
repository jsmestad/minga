defmodule Minga.Theme.DoomOne do
  @moduledoc """
  Doom One theme, sourced from doomemacs/themes doom-one-theme.el.

  A dark theme with vibrant accent colors on a muted background. This is
  Minga's default theme.
  """

  # ── Doom One palette ──────────────────────────────────────────────────
  @blue 0x51AFEF
  @red 0xFF6C6B
  @magenta 0xC678DD
  @green 0x98BE65
  @orange 0xDA8548
  @yellow 0xECBE7B
  @cyan 0x46D9FF
  @teal 0x4DB5BD
  @violet 0xA9A1E1
  @fg 0xBBC2CF
  @grey 0x5B6268
  @light_grey 0x818990
  @bg 0x282C34
  @base3 0x23272E
  @base5 0x5B6268
  @base6 0x73797E
  @base8 0xDFDFDF

  @doc "Returns the Doom One theme struct."
  @spec theme() :: Minga.Theme.t()
  def theme do
    %Minga.Theme{
      name: :doom_one,
      syntax: syntax(),
      editor: %Minga.Theme.Editor{
        bg: @bg,
        fg: @fg,
        tilde_fg: @base5,
        split_border_fg: @base5
      },
      gutter: %Minga.Theme.Gutter{
        fg: @base5,
        current_fg: @fg,
        error_fg: @red,
        warning_fg: @yellow,
        info_fg: @blue,
        hint_fg: @base5
      },
      git: %Minga.Theme.Git{
        added_fg: @green,
        modified_fg: @blue,
        deleted_fg: @red
      },
      modeline: %Minga.Theme.Modeline{
        bar_fg: @fg,
        bar_bg: @base3,
        info_fg: @fg,
        info_bg: 0x3F444A,
        filetype_fg: @green,
        mode_colors: %{
          normal: {0x000000, @blue},
          insert: {0x000000, @green},
          visual: {0x000000, @magenta},
          operator_pending: {0x000000, @orange},
          command: {0x000000, @yellow},
          replace: {0x000000, @red},
          search: {0x000000, @cyan}
        }
      },
      picker: %Minga.Theme.Picker{
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
      minibuffer: %Minga.Theme.Minibuffer{
        fg: @base8,
        bg: 0x000000,
        warning_fg: 0xFFCC00,
        dim_fg: @base6
      },
      search: %Minga.Theme.Search{
        highlight_fg: 0x000000,
        highlight_bg: @yellow,
        current_bg: @red
      },
      popup: %Minga.Theme.Popup{
        fg: @base8,
        bg: 0x333333,
        border_fg: @base6
      },
      tree: %Minga.Theme.Tree{
        bg: @base3,
        fg: @fg,
        dir_fg: @blue,
        active_fg: @green,
        cursor_bg: 0x3E4451,
        header_fg: @blue,
        header_bg: @base3,
        separator_fg: @base5
      }
    }
  end

  @spec syntax() :: Minga.Theme.syntax()
  defp syntax do
    %{
      # ── Keywords ────────────────────────────────────────────────────────
      "keyword" => [fg: @magenta, bold: true],
      "keyword.function" => [fg: @magenta, bold: true],
      "keyword.operator" => [fg: @magenta],
      "keyword.return" => [fg: @magenta, bold: true],
      "keyword.conditional" => [fg: @magenta, bold: true],
      "keyword.coroutine" => [fg: @magenta, bold: true],
      "keyword.directive" => [fg: @magenta],
      "keyword.exception" => [fg: @magenta],
      "keyword.import" => [fg: @magenta],
      "keyword.modifier" => [fg: @magenta, bold: true],
      "keyword.repeat" => [fg: @magenta, bold: true],
      "keyword.type" => [fg: @magenta, bold: true],
      "conditional" => [fg: @magenta, bold: true],
      "exception" => [fg: @magenta],
      "include" => [fg: @magenta],
      "import" => [fg: @magenta],
      "repeat" => [fg: @magenta, bold: true],

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
      "function" => [fg: @blue],
      "function.call" => [fg: @blue],
      "function.builtin" => [fg: @teal],
      "function.macro" => [fg: @magenta, bold: true],
      "function.method" => [fg: @blue],
      "function.method.builtin" => [fg: @teal],
      "function.special" => [fg: @magenta],
      "method" => [fg: @blue],
      "method.call" => [fg: @blue],

      # ── Types ───────────────────────────────────────────────────────────
      "type" => [fg: @yellow],
      "type.builtin" => [fg: @yellow, bold: true],

      # ── Variables ───────────────────────────────────────────────────────
      "variable" => [fg: @fg],
      "variable.builtin" => [fg: @orange],
      "variable.parameter" => [fg: @red],
      "variable.member" => [fg: @teal],
      "parameter" => [fg: @red],
      "field" => [fg: @teal],

      # ── Constants & numbers ─────────────────────────────────────────────
      "constant" => [fg: @orange],
      "constant.builtin" => [fg: @orange, bold: true],
      "boolean" => [fg: @orange, bold: true],
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

      # ── Text / markup ──────────────────────────────────────────────────
      "text.title" => [fg: @red, bold: true],
      "text.strong" => [fg: @orange, bold: true],
      "text.emphasis" => [fg: @magenta, italic: true],
      "text.literal" => [fg: @green],
      "text.uri" => [fg: @cyan, underline: true],
      "text.reference" => [fg: @blue],

      # ── CSS-specific ───────────────────────────────────────────────────
      "charset" => [fg: @magenta, bold: true],
      "keyframes" => [fg: @magenta, bold: true],
      "media" => [fg: @magenta, bold: true],
      "supports" => [fg: @magenta, bold: true],

      # ── Misc ───────────────────────────────────────────────────────────
      "escape" => [fg: @orange],
      "embedded" => [fg: @fg],
      "constructor" => [fg: @yellow, bold: true],
      "error" => [fg: @red, bold: true],
      "warning" => [fg: @yellow, bold: true]
    }
  end
end
