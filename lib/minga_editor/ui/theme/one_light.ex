defmodule MingaEditor.UI.Theme.OneLight do
  @moduledoc """
  One Light theme, based on Atom's One Light syntax theme.

  Atom's `one-light-syntax` does not define Minga-specific chrome like agent panels, dashboards, tree sidebars, tab bars, or pickers. Those surfaces derive from the semantic theme builder so they stay consistent with the upstream palette without copying a large hand-wired map.
  """

  alias MingaEditor.UI.Theme.Builder
  alias MingaEditor.UI.Theme.Palette

  # ── One Light palette (Atom) ──────────────────────────────────────────
  @mono_1 0x383A42
  @mono_2 0x696C77
  @mono_3 0xA0A1A7
  @hue_1 0x0184BC
  @hue_2 0x4078F2
  @hue_3 0xA626A4
  @hue_4 0x50A14F
  @hue_5 0xE45649
  @hue_6 0xC18401
  @hue_6_2 0x986801
  @syntax_bg 0xFAFAFA
  @syntax_gutter 0x9D9D9F
  @syntax_guide 0xEAEAEA
  @ui_bg 0xF0F0F0
  @ui_fg 0x616161
  @syntax_selection 0xE6E6E6
  @syntax_color_modified 0xF2A60D

  @doc "Returns the One Light theme struct."
  @spec theme() :: MingaEditor.UI.Theme.t()
  def theme do
    Builder.from_palette(:one_light, palette(), overrides())
  end

  @spec palette() :: Palette.t()
  defp palette do
    Palette.new(%{
      variant: :light,
      bg: @syntax_bg,
      fg: @mono_1,
      surface: @ui_bg,
      overlay: @ui_bg,
      muted: @syntax_gutter,
      subtle: @syntax_guide,
      accent: @hue_2,
      highlight: @hue_2,
      selection_bg: @syntax_selection,
      error: @hue_5,
      warning: @syntax_color_modified,
      info: @hue_2,
      success: @hue_4,
      match: @hue_6,
      link: @hue_1,
      border: @syntax_guide,
      contrast_fg: 0xFFFFFF,
      builtin: @hue_1,
      functions: @hue_2,
      keywords: @hue_3,
      methods: @hue_2,
      operators: @mono_1,
      constants: @hue_6,
      strings: @hue_4,
      numbers: @hue_6,
      type: @hue_6_2,
      variables: @hue_5,
      comments: @mono_3
    })
  end

  @spec overrides() :: Builder.overrides()
  defp overrides do
    %{
      editor: %{
        cursorline_bg: @syntax_selection,
        nav_flash_bg: 0xE0E0E0,
        yank_flash_bg: 0xD5D5D5,
        highlight_read_bg: 0xD0D5DC,
        highlight_write_bg: 0xE8D8B8,
        whitespace_fg: @syntax_gutter,
        indent_guide_fg: @syntax_guide,
        indent_guide_active_fg: @mono_3
      },
      gutter: %{
        current_fg: @mono_1,
        warning_fg: @hue_6,
        hint_fg: @syntax_gutter,
        fold_fg: @syntax_gutter,
        separator_fg: @syntax_gutter
      },
      modeline: %{
        bar_fg: @ui_fg,
        info_fg: @mono_1,
        info_bg: @syntax_guide,
        mode_colors: %{
          normal: {0xFFFFFF, @hue_2},
          insert: {0xFFFFFF, @hue_4},
          visual: {0xFFFFFF, @hue_3},
          operator_pending: {0xFFFFFF, @hue_6},
          command: {0xFFFFFF, @hue_6_2},
          replace: {0xFFFFFF, @hue_5},
          search: {0xFFFFFF, @hue_1}
        }
      },
      popup: %{bg: @syntax_guide, border_fg: @mono_3, sel_bg: @hue_2, separator_fg: @mono_2},
      tree: %{
        bg: @ui_bg,
        cursor_bg: @syntax_selection,
        header_bg: @ui_bg,
        separator_fg: @mono_3,
        modified_fg: @syntax_color_modified,
        git_untracked_fg: @mono_3
      },
      syntax: syntax_overrides()
    }
  end

  @spec syntax_overrides() :: MingaEditor.UI.Theme.syntax()
  defp syntax_overrides do
    %{
      "string.special.regex" => [fg: @hue_1],
      "string.escape" => [fg: @hue_1],
      "string.regex" => [fg: @hue_1],
      "character" => [fg: @hue_6],
      "variable.parameter" => [fg: @mono_1],
      "parameter" => [fg: @mono_1],
      "variable.member" => [fg: @mono_1],
      "field" => [fg: @mono_1],
      "property" => [fg: @mono_1],
      "attribute" => [fg: @hue_6],
      "tag.attribute" => [fg: @hue_6],
      "escape" => [fg: @hue_1],
      "punctuation.bracket" => [fg: @mono_1],
      "punctuation.delimiter" => [fg: @mono_1],
      "delimiter" => [fg: @mono_1]
    }
  end
end
