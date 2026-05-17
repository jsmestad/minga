defmodule MingaEditor.UI.Theme.OneLightTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Theme

  @palette %{
    mono_1: 0x383A42,
    mono_2: 0x696C77,
    mono_3: 0xA0A1A7,
    hue_1: 0x0184BC,
    hue_2: 0x4078F2,
    hue_3: 0xA626A4,
    hue_4: 0x50A14F,
    hue_5: 0xE45649,
    hue_6: 0xC18401,
    hue_6_2: 0x986801,
    syntax_bg: 0xFAFAFA,
    syntax_gutter: 0x9D9D9F,
    syntax_guide: 0xEAEAEA,
    ui_bg: 0xF0F0F0,
    syntax_selection: 0xE6E6E6,
    syntax_color_modified: 0xF2A60D
  }

  test "uses Atom One Light palette values and semantic-layer expansion" do
    theme = Theme.get!(:one_light)
    p = @palette

    assert theme.editor.bg == p.syntax_bg
    assert theme.editor.fg == p.mono_1
    assert theme.editor.selection_bg == p.syntax_selection
    assert theme.editor.cursorline_bg == p.syntax_selection
    assert theme.gutter.fg == p.syntax_gutter
    assert theme.gutter.current_fg == p.mono_1
    assert theme.git.added_fg == p.hue_4
    assert theme.git.modified_fg == p.syntax_color_modified
    assert theme.git.deleted_fg == p.hue_5
    assert theme.tree.modified_fg == p.syntax_color_modified
    assert theme.tree.git_modified_fg == p.syntax_color_modified
    assert theme.popup.title_fg == p.hue_2
    assert theme.agent.link_fg == p.hue_1
  end

  test "maps tree-sitter captures to upstream Atom syntax roles" do
    theme = Theme.get!(:one_light)
    p = @palette

    assert theme.syntax["keyword"] == [fg: p.hue_3, bold: true]
    assert theme.syntax["keyword.operator"] == [fg: p.mono_1]
    assert theme.syntax["operator"] == [fg: p.mono_1]
    assert theme.syntax["variable"] == [fg: p.hue_5]
    assert theme.syntax["variable.parameter"] == [fg: p.mono_1]
    assert theme.syntax["parameter"] == [fg: p.mono_1]
    assert theme.syntax["property"] == [fg: p.mono_1]
    assert theme.syntax["field"] == [fg: p.mono_1]
    assert theme.syntax["string.regex"] == [fg: p.hue_1]
    assert theme.syntax["string.special.regex"] == [fg: p.hue_1]
    assert theme.syntax["string.escape"] == [fg: p.hue_1]
    assert theme.syntax["escape"] == [fg: p.hue_1]
    assert theme.syntax["constant"] == [fg: p.hue_6]
    assert theme.syntax["number"] == [fg: p.hue_6]
    assert theme.syntax["function"] == [fg: p.hue_2]
  end
end
