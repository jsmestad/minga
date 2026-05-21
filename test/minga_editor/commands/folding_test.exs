defmodule MingaEditor.Commands.FoldingTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Fold.Range, as: FoldRange
  alias MingaEditor.Commands.Folding
  alias MingaEditor.FoldMap
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  describe "execute_at_line/2" do
    test "toggles the fold at the given line without using the cursor line" do
      state = editor_state_with_fold_range(FoldRange.new!(5, 9))

      state = Folding.execute_at_line(state, 5)
      window = EditorState.active_window_struct(state)

      assert FoldMap.fold_at(window.fold_map, 5) != :none
      assert FoldMap.fold_at(window.fold_map, 0) == :none
    end

    test "toggles an already folded line back open" do
      state = editor_state_with_fold_range(FoldRange.new!(5, 9))

      state = Folding.execute_at_line(state, 5)
      state = Folding.execute_at_line(state, 5)
      window = EditorState.active_window_struct(state)

      assert FoldMap.fold_at(window.fold_map, 5) == :none
    end

    test "targets the requested window instead of the active window" do
      state = editor_state_with_two_windows(FoldRange.new!(5, 9))

      state = Folding.execute_at_line(state, 2, 5)

      active_window = state.workspace.windows.map[1]
      clicked_window = state.workspace.windows.map[2]

      assert FoldMap.fold_at(active_window.fold_map, 5) == :none
      assert FoldMap.fold_at(clicked_window.fold_map, 5) != :none
      assert state.workspace.windows.active == 1
    end
  end

  defp editor_state_with_fold_range(range) do
    buffer = spawn(fn -> :ok end)

    window =
      1
      |> Window.new(buffer, 24, 80)
      |> Window.set_fold_ranges([range])

    windows =
      %Windows{}
      |> Windows.set_tree(WindowTree.new(1))
      |> Windows.set_map(%{1 => window})
      |> Windows.set_active(1)

    workspace =
      %SessionState{viewport: Viewport.new(24, 80)}
      |> SessionState.set_windows(windows)

    %EditorState{port_manager: nil, workspace: workspace}
  end

  defp editor_state_with_two_windows(range) do
    buffer = spawn(fn -> :ok end)

    active_window =
      1
      |> Window.new(buffer, 24, 80)
      |> Window.set_fold_ranges([range])

    clicked_window =
      2
      |> Window.new(buffer, 24, 80)
      |> Window.set_fold_ranges([range])

    windows =
      %Windows{}
      |> Windows.set_tree(WindowTree.new(1))
      |> Windows.set_map(%{1 => active_window, 2 => clicked_window})
      |> Windows.set_active(1)

    workspace =
      %SessionState{viewport: Viewport.new(24, 80)}
      |> SessionState.set_windows(windows)

    %EditorState{port_manager: nil, workspace: workspace}
  end
end
