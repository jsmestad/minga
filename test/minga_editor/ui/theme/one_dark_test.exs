defmodule MingaEditor.UI.Theme.OneDarkTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Theme

  @palette %{
    mono_1: 0xABB2BF,
    mono_2: 0x818896,
    mono_3: 0x5C6370,
    hue_1: 0x56B6C2,
    hue_2: 0x61AFEF,
    hue_3: 0xC678DD,
    hue_4: 0x98C379,
    hue_5: 0xE06C75,
    hue_6: 0xD19A66,
    hue_6_2: 0xE5C07B,
    syntax_bg: 0x282C34,
    syntax_gutter: 0x636D83,
    syntax_guide: 0x3B4048,
    ui_bg: 0x21252B,
    syntax_selection: 0x3E4451,
    syntax_gutter_selected: 0x3A404B,
    syntax_color_modified: 0xE0C285
  }

  test "uses Atom One Dark palette values and semantic-layer expansion" do
    theme = Theme.get!(:one_dark)
    p = @palette

    assert theme.editor.bg == p.syntax_bg
    assert theme.editor.fg == p.mono_1
    assert theme.editor.selection_bg == p.syntax_selection
    assert theme.editor.cursorline_bg == p.syntax_gutter_selected
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
    theme = Theme.get!(:one_dark)
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
    assert theme.syntax["constant"] == [fg: p.hue_6]
    assert theme.syntax["number"] == [fg: p.hue_6]
    assert theme.syntax["function"] == [fg: p.hue_2]
  end
end
