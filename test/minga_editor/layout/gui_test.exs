defmodule MingaEditor.Layout.GUITest do
  use ExUnit.Case, async: true

  alias MingaEditor.Layout
  alias MingaEditor.Layout.GUI, as: LayoutGUI
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout.SurfaceRegistry
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Frontend
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
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

    test "minibuffer sits just below the content grid (native chrome, not reserved)" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      {row, 0, _, 1} = layout.minibuffer
      # Native GUI renders the minibuffer outside the Metal surface, so no grid
      # row is reserved: the rect is anchored on the row directly below content.
      assert row == state.frontend.terminal_viewport.rows
    end

    test "editor fills the full viewport for native GUI (no phantom minibuffer row)" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      {_r, _c, _w, editor_h} = layout.editor_area
      assert editor_h == state.frontend.terminal_viewport.rows
    end

    test "single window has no per-window modeline field" do
      state = gui_state()
      layout = LayoutGUI.compute(state)

      win_layout = layout.window_layouts |> Map.values() |> hd()
      refute Map.has_key?(win_layout, :modeline)
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

  test "Agent timeline reservation stays separate from content and footer across background bursts" do
    for {cols, rows} <- [{140, 40}, {60, 24}], body <- [:chat, :review], count <- [0, 1, 100] do
      state = agent_state(body, count, :tui, cols, rows)
      layout = LayoutGUI.compute(state)
      assert layout.edit_timeline == {rows - 4, 0, cols, 3}
      assert layout.editor_area == {0, 0, cols, rows - 4}
      assert layout.minibuffer == {rows - 1, 0, cols, 1}
      assert SurfaceRegistry.rect_for(state, :edit_timeline) == layout.edit_timeline
    end
  end

  test "a visible minibuffer has its own row below the timeline and status" do
    state = agent_state(:chat, 0, :tui, 140, 40)

    workspace =
      SessionState.transition_mode(
        state.workspace,
        :command,
        Minga.Mode.CommandState.new("write")
      )

    state = %{state | workspace: workspace}

    for input <- [state, MingaEditor.RenderPipeline.Input.from_editor_state(state)] do
      layout = LayoutGUI.compute(input)
      assert layout.editor_area == {0, 0, 140, 35}
      assert layout.edit_timeline == {35, 0, 140, 3}
      assert layout.minibuffer == {39, 0, 140, 1}
    end
  end

  test "native Agent chrome never subtracts timeline rows from the already fitted editor" do
    for body <- [:chat, :review], count <- [0, 1, 100] do
      state = agent_state(body, count, :native_gui, 80, 24)
      layout = LayoutGUI.compute(state)
      assert layout.editor_area == {0, 0, 80, 24}
      assert layout.edit_timeline == nil
    end
  end

  defp agent_state(body, count, frontend_type, cols, rows) do
    state = base_state(rows: rows, cols: cols)

    frontend =
      Frontend.accept_capabilities(state.frontend, %Capabilities{
        frontend_type: frontend_type,
        semantic_ui: true
      })

    id = state.workspace.windows.active
    window = Window.new_agent_chat(id, rows, cols)
    windows = Windows.replace_window(state.workspace.windows, id, window)

    timeline =
      Enum.reduce(1..count//1, EditTimeline.new(), fn index, timeline ->
        EditTimeline.record_edit(
          timeline,
          "file-#{index}.ex",
          "call-#{index}",
          "edit_file",
          "before",
          "after"
        )
      end)

    ui = UIState.replace_edit_timeline(UIState.new(), timeline)

    ui =
      if body == :review do
        ui
        |> UIState.replace_preview(
          Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "after"))
        )
        |> UIState.set_focus(:file_viewer)
      else
        ui
      end

    workspace =
      state.workspace |> SessionState.set_windows(windows) |> SessionState.set_agent_ui(ui)

    %{state | frontend: frontend, workspace: workspace}
  end
end
