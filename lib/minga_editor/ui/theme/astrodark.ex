defmodule MingaEditor.UI.Theme.AstroDark do
  @moduledoc """
  AstroDark theme, ported from AstroNvim's astrotheme (`astrodark` palette).

  This theme exists primarily as a 1:1 visual reference so Minga's TUI surfaces can be compared directly against AstroNvim. The palette is split the same way astrotheme splits it: a brighter `ui` group drives chrome and diagnostics, and a slightly muted `syntax` group drives in-buffer tree-sitter captures. Chrome surfaces Minga defines but AstroNvim does not derive from the semantic builder so they stay consistent with the upstream palette.

  Source: https://github.com/AstroNvim/astrotheme/blob/main/lua/astrotheme/palettes/astrodark.lua
  """

  alias MingaEditor.UI.Theme.Builder
  alias MingaEditor.UI.Theme.Palette

  # ── AstroDark `ui` group (chrome, diagnostics) ────────────────────────
  @ui_red 0xF8747E
  @ui_yellow 0xD09214
  @ui_green 0x75AD47
  @ui_blue 0x50A4E9
  @ui_border 0x3A3E47

  # ── AstroDark `syntax` group (in-buffer captures) ─────────────────────
  @syn_red 0xFF838B
  @syn_orange 0xF5983A
  @syn_yellow 0xDFAB25
  @syn_green 0x87C05F
  @syn_cyan 0x4AC2B8
  @syn_blue 0x5EB7FF
  @syn_purple 0xDD97F1
  @syn_text 0xADB0BB
  @syn_comment 0x696C76
  @syn_mute 0x595C66

  # ── AstroDark structural surfaces (dark, layered) ─────────────────────
  @bg_base 0x1A1D23
  @bg_tool 0x16181D
  @bg_statusline 0x111317
  @bg_float 0x14161B
  @bg_current_line 0x1E222A
  @bg_selection 0x26343F
  @bg_inactive 0x16181D
  @ui_highlight 0x23272F
  @indent_guide 0x2D313A
  @indent_guide_active 0x494D56

  @doc "Returns the AstroDark theme struct."
  @spec theme() :: MingaEditor.UI.Theme.t()
  def theme do
    Builder.from_palette(:astrodark, palette(), overrides())
  end

  @spec palette() :: Palette.t()
  defp palette do
    Palette.new(%{
      variant: :dark,
      bg: @bg_base,
      fg: @syn_text,
      surface: @bg_tool,
      overlay: @bg_statusline,
      muted: @syn_mute,
      subtle: @indent_guide,
      accent: @ui_blue,
      highlight: @ui_blue,
      selection_bg: @bg_selection,
      error: @ui_red,
      warning: @ui_yellow,
      info: @ui_blue,
      success: @ui_green,
      match: @syn_yellow,
      link: @ui_blue,
      border: @ui_border,
      contrast_fg: @bg_base,
      builtin: @syn_cyan,
      functions: @syn_blue,
      keywords: @syn_purple,
      methods: @syn_blue,
      operators: @syn_text,
      constants: @syn_orange,
      strings: @syn_green,
      numbers: @syn_orange,
      type: @syn_yellow,
      variables: @syn_text,
      comments: @syn_comment
    })
  end

  @spec overrides() :: Builder.overrides()
  defp overrides do
    %{
      editor: %{
        cursorline_bg: @bg_current_line,
        highlight_read_bg: @ui_highlight,
        indent_guide_fg: @indent_guide,
        indent_guide_active_fg: @indent_guide_active
      },
      popup: %{bg: @bg_float},
      tab_bar: %{bg: @bg_statusline, inactive_bg: @bg_inactive},
      syntax: syntax_overrides(),
      icon: icon_overrides()
    }
  end

  # AstroNvim's astrotheme ships a per-filetype icon palette (the `c.icon` table),
  # keyed here by Minga filetype atom. Folders use the UI accent. Filetypes not
  # listed fall back to the language's default `icon_color`.
  @spec icon_overrides() :: MingaEditor.UI.Theme.icon_overrides()
  defp icon_overrides do
    %{
      directory: @ui_blue,
      c: 0x519ABA,
      css: 0x61AFEF,
      dockerfile: 0x384D54,
      html: 0xDE8C92,
      javascript: 0xEBCB8B,
      javascript_react: 0x519AB8,
      kotlin: 0x7BC99C,
      lua: 0x51A0CF,
      markdown: 0x519ABA,
      python: 0xA3B8EF,
      ruby: 0xFF75A0,
      rust: 0xDEA584,
      toml: 0x39BF39,
      typescript: 0x519ABA,
      typescript_react: 0x519ABA
    }
  end

  @spec syntax_overrides() :: MingaEditor.UI.Theme.syntax()
  defp syntax_overrides do
    %{
      # AstroNvim renders members/parameters as plain text, not as accents.
      "variable.parameter" => [fg: @syn_text],
      "parameter" => [fg: @syn_text],
      "variable.member" => [fg: @syn_text],
      "field" => [fg: @syn_text],
      # Config/document keys (YAML, JSON, TOML, ...) capture as @property. Give
      # it a visible accent so key-heavy files stay readable, matching how modern
      # editors highlight keys. Code member access stays muted via @variable.member
      # / @field above. Without this, @property would equal the editor foreground
      # and keys would render as plain text.
      "property" => [fg: @syn_purple],
      "tag.attribute" => [fg: @syn_orange],
      "attribute" => [fg: @syn_orange],
      "string.special.regex" => [fg: @syn_red],
      "string.regex" => [fg: @syn_red]
    }
  end
end
