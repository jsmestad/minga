defmodule MingaEditor.UI.Theme.OneDark do
  @moduledoc """
  One Dark theme, based on Atom's One Dark syntax theme.

  Atom's `one-dark-syntax` does not define Minga-specific chrome like agent panels, dashboards, tree sidebars, tab bars, or pickers. Those surfaces derive from the semantic theme builder so they stay consistent with the upstream palette without copying a large hand-wired map.
  """

  alias MingaEditor.UI.Theme.Builder
  alias MingaEditor.UI.Theme.Palette

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
  @syntax_selection 0x3E4451
  @syntax_gutter_selected 0x3A404B
  @syntax_color_modified 0xE0C285

  @doc "Returns the One Dark theme struct."
  @spec theme() :: MingaEditor.UI.Theme.t()
  def theme do
    Builder.from_palette(:one_dark, palette(), overrides())
  end

  @spec palette() :: Palette.t()
  defp palette do
    Palette.new(%{
      variant: :dark,
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
      match: @hue_6_2,
      link: @hue_1,
      border: @syntax_guide,
      contrast_fg: 0x000000,
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
        cursorline_bg: @syntax_gutter_selected,
        nav_flash_bg: @syntax_selection,
        yank_flash_bg: 0x4B5263,
        highlight_read_bg: @syntax_gutter_selected,
        highlight_write_bg: 0x4A3F2B,
        whitespace_fg: @syntax_gutter,
        indent_guide_fg: @syntax_guide,
        indent_guide_active_fg: @mono_3
      },
      gutter: %{
        current_fg: @mono_1,
        warning_fg: @hue_6_2,
        hint_fg: @syntax_gutter,
        fold_fg: @syntax_gutter,
        separator_fg: @syntax_gutter
      },
      modeline: %{
        info_bg: @syntax_guide,
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
      minibuffer: %{bg: 0x000000},
      popup: %{bg: @syntax_guide, border_fg: @mono_2, sel_bg: @hue_2, separator_fg: @mono_3},
      tree: %{
        bg: @ui_bg,
        cursor_bg: @syntax_guide,
        header_bg: @ui_bg,
        separator_fg: @syntax_gutter,
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
      "string.regex" => [fg: @hue_1],
      "character" => [fg: @hue_6],
      "variable.parameter" => [fg: @mono_1],
      "parameter" => [fg: @mono_1],
      "variable.member" => [fg: @mono_1],
      "field" => [fg: @mono_1],
      "property" => [fg: @mono_1],
      "attribute" => [fg: @hue_6],
      "tag.attribute" => [fg: @hue_6],
      "punctuation.bracket" => [fg: @mono_1],
      "punctuation.delimiter" => [fg: @mono_1],
      "delimiter" => [fg: @mono_1]
    }
  end
end
