defmodule MingaEditor.UI.Theme.AstroDarkTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Theme

  @palette %{
    ui_red: 0xF8747E,
    ui_yellow: 0xD09214,
    ui_green: 0x75AD47,
    ui_blue: 0x50A4E9,
    ui_border: 0x3A3E47,
    syn_red: 0xFF838B,
    syn_orange: 0xF5983A,
    syn_yellow: 0xDFAB25,
    syn_green: 0x87C05F,
    syn_cyan: 0x4AC2B8,
    syn_blue: 0x5EB7FF,
    syn_purple: 0xDD97F1,
    syn_text: 0xADB0BB,
    syn_comment: 0x696C76,
    bg_base: 0x1A1D23,
    bg_tool: 0x16181D,
    bg_statusline: 0x111317,
    bg_float: 0x14161B,
    bg_current_line: 0x1E222A,
    bg_selection: 0x26343F
  }

  test "uses AstroDark structural surfaces and semantic-layer expansion" do
    theme = Theme.get!(:astrodark)
    p = @palette

    assert theme.editor.bg == p.bg_base
    assert theme.editor.fg == p.syn_text
    assert theme.editor.selection_bg == p.bg_selection
    assert theme.editor.cursorline_bg == p.bg_current_line
    assert theme.tree.bg == p.bg_tool
    assert theme.modeline.bar_bg == p.bg_statusline
    assert theme.popup.bg == p.bg_float
    assert theme.editor.highlight_read_bg == 0x23272F
    assert theme.tab_bar.inactive_bg == 0x16181D
    assert theme.tab_bar.bg == p.bg_statusline
    assert theme.gutter.error_fg == p.ui_red
    assert theme.gutter.warning_fg == p.ui_yellow
    assert theme.git.added_fg == p.ui_green
    assert theme.popup.title_fg == p.ui_blue
    assert theme.agent.link_fg == p.ui_blue
  end

  test "maps tree-sitter captures to the muted AstroDark syntax group" do
    theme = Theme.get!(:astrodark)
    p = @palette

    assert theme.syntax["keyword"] == [fg: p.syn_purple, bold: true]
    assert theme.syntax["function"] == [fg: p.syn_blue]
    assert theme.syntax["function.builtin"] == [fg: p.syn_cyan]
    assert theme.syntax["string"] == [fg: p.syn_green]
    assert theme.syntax["number"] == [fg: p.syn_orange]
    assert theme.syntax["constant"] == [fg: p.syn_orange]
    assert theme.syntax["type"] == [fg: p.syn_yellow]
    assert theme.syntax["comment"] == [fg: p.syn_comment, italic: true]
    assert theme.syntax["operator"] == [fg: p.syn_text]
    assert theme.syntax["variable.parameter"] == [fg: p.syn_text]
    assert theme.syntax["property"] == [fg: p.syn_purple]
    assert theme.syntax["field"] == [fg: p.syn_text]
    assert theme.syntax["string.regex"] == [fg: p.syn_red]
  end

  test "gives config-document keys (@property) a visible accent distinct from editor fg" do
    theme = Theme.get!(:astrodark)
    p = @palette

    # Config/document keys (YAML, JSON, TOML, ...) capture as @property and get a
    # visible accent so key-heavy files stay readable, matching nvim-treesitter.
    assert theme.syntax["property"] == [fg: p.syn_purple]

    # The accent must differ from the editor's default foreground (@syn_text);
    # otherwise keys would render as plain text (the bug we fixed).
    refute theme.syntax["property"] == [fg: p.syn_text]
    assert p.syn_purple != p.syn_text

    # Code member access stays muted on the editor foreground, so we did not
    # broaden scope to recoloring struct/field access in code.
    assert theme.syntax["variable.member"] == [fg: p.syn_text]
    assert theme.syntax["field"] == [fg: p.syn_text]

    # The legacy YAML-specific capture no longer exists.
    refute Map.has_key?(theme.syntax, "property.yaml")
  end

  describe "icon_color/2" do
    test "overrides per-filetype icon colors from astrotheme's palette" do
      theme = Theme.get!(:astrodark)

      assert Theme.icon_color(theme, :lua) == 0x51A0CF
      assert Theme.icon_color(theme, :python) == 0xA3B8EF
      assert Theme.icon_color(theme, :rust) == 0xDEA584
      assert Theme.icon_color(theme, :ruby) == 0xFF75A0
    end

    test "colors folders with the UI accent via the :directory key" do
      assert Theme.icon_color(Theme.get!(:astrodark), :directory) == 0x50A4E9
    end

    test "falls back to the language default for filetypes it does not override" do
      theme = Theme.get!(:astrodark)
      # :elixir is not in astrodark's icon map, so it keeps the language default.
      assert Theme.icon_color(theme, :elixir) == Minga.Language.Devicon.color(:elixir)
    end
  end
end
