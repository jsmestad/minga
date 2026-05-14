defmodule MingaEditor.Shell.Traditional.Layout.TUITest do
  use ExUnit.Case, async: true

  alias MingaEditor.Layout
  alias MingaEditor.Shell.Traditional.Layout.TUI, as: LayoutTUI

  import MingaEditor.RenderPipeline.TestHelpers

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

    test "reserves sidebar space when git status panel is open" do
      state =
        base_state(cols: 80, rows: 24)
        |> MingaEditor.State.set_git_status_panel(%{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      layout = LayoutTUI.compute(state)

      assert {1, 0, 20, 21} = layout.file_tree
      assert {1, 21, 59, 21} = layout.editor_area
    end
  end
end
