defmodule MingaEditor.Layout.GUITest do
  use ExUnit.Case, async: true

  alias MingaEditor.Layout
  alias MingaEditor.Layout.GUI, as: LayoutGUI
  import MingaEditor.RenderPipeline.TestHelpers

  describe "Layout.GUI.compute/1" do
    test "returns a Layout struct" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      assert %Layout{} = layout
    end

    test "no tab bar (SwiftUI handles it)" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      assert layout.tab_bar == nil
    end

    test "no file tree (SwiftUI handles it)" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      assert layout.file_tree == nil
    end

    test "no agent panel (SwiftUI handles it)" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      assert layout.agent_panel == nil
    end

    test "editor area starts at row 0 (no tab bar)" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      {row, col, _w, _h} = layout.editor_area
      assert row == 0
      assert col == 0
    end

    test "minibuffer is the last row" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      {row, 0, _, 1} = layout.minibuffer
      assert row == state.workspace.viewport.rows - 1
    end

    test "single window has no modeline row" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      win_layout = layout.window_layouts |> Map.values() |> hd()
      {_row, _col, _w, modeline_h} = win_layout.modeline
      assert modeline_h == 0
    end

    test "content fills the full editor area height" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      {_r, _c, _w, editor_h} = layout.editor_area
      win_layout = layout.window_layouts |> Map.values() |> hd()
      {_r, _c, _w, content_h} = win_layout.content
      assert content_h == editor_h
    end
  end
end
