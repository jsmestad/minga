defmodule MingaEditor.Shell.Traditional.Layout.TUITest do
  use ExUnit.Case, async: true

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.Shell.Traditional.Layout.TUI, as: LayoutTUI

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    %{sidebar_registry: table}
  end

  describe "Layout.TUI.compute/1" do
    test "returns a Layout struct", %{sidebar_registry: table} do
      state = base_state(sidebar_registry: table)
      layout = LayoutTUI.compute(state)

      assert %Layout{} = layout
    end

    test "includes tab bar at row 0", %{sidebar_registry: table} do
      state = base_state(sidebar_registry: table)
      layout = LayoutTUI.compute(state)

      assert {0, 0, _, 1} = layout.tab_bar
    end

    test "minibuffer is the last row", %{sidebar_registry: table} do
      state = base_state(rows: 24, sidebar_registry: table)
      layout = LayoutTUI.compute(state)

      assert {23, 0, _, 1} = layout.minibuffer
    end

    test "editor area starts at row 1 (below tab bar)", %{sidebar_registry: table} do
      state = base_state(sidebar_registry: table)
      layout = LayoutTUI.compute(state)

      {row, _col, _w, _h} = layout.editor_area
      assert row == 1
    end

    test "produces window layouts", %{sidebar_registry: table} do
      state = base_state(sidebar_registry: table)
      layout = LayoutTUI.compute(state)

      assert map_size(layout.window_layouts) > 0
    end

    test "no file tree when none is open", %{sidebar_registry: table} do
      state = base_state(sidebar_registry: table)
      layout = LayoutTUI.compute(state)

      assert layout.file_tree == nil
    end

    test "reserves sidebar space when git status panel is open", %{sidebar_registry: table} do
      state =
        base_state(cols: 80, rows: 24, sidebar_registry: table)
        |> MingaEditor.State.set_git_status_panel(%{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      layout = LayoutTUI.compute(state)

      assert {1, 0, 30, 21} = layout.file_tree
      assert {1, 31, 49, 21} = layout.editor_area
    end
  end
end
