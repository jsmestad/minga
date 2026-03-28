defmodule Minga.Shell.Traditional.Layout.TUITest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Layout
  alias Minga.Shell.Traditional.Layout.TUI, as: LayoutTUI

  import Minga.Editor.RenderPipeline.TestHelpers

  describe "Layout.TUI.compute/1" do
    test "returns a Layout struct" do
      state = base_state()
      layout = LayoutTUI.compute(state)

      assert %Layout{} = layout
    end

    test "includes tab bar at row 0" do
      state = base_state()
      layout = LayoutTUI.compute(state)

      assert {0, 0, _, 1} = layout.tab_bar
    end

    test "minibuffer is the last row" do
      state = base_state(rows: 24)
      layout = LayoutTUI.compute(state)

      assert {23, 0, _, 1} = layout.minibuffer
    end

    test "editor area starts at row 1 (below tab bar)" do
      state = base_state()
      layout = LayoutTUI.compute(state)

      {row, _col, _w, _h} = layout.editor_area
      assert row == 1
    end

    test "produces window layouts" do
      state = base_state()
      layout = LayoutTUI.compute(state)

      assert map_size(layout.window_layouts) > 0
    end

    test "no file tree when none is open" do
      state = base_state()
      layout = LayoutTUI.compute(state)

      assert layout.file_tree == nil
    end
  end
end
