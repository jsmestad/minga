defmodule MingaEditor.Agent.UIState.PresentationTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState.Presentation
  alias MingaEditor.Agent.UIState.ReturnTarget
  alias MingaEditor.State.FileTree
  alias MingaEditor.State.Windows

  test "replacement activation installs one coherent return context and clears local input state" do
    first_windows = %Windows{active: 1, next_id: 2}
    second_windows = %Windows{active: 2, next_id: 3}
    first_tree = %FileTree{visibility: :focused}
    second_tree = %FileTree{visibility: :visible}
    first_target = return_target(1, first_windows, first_tree)
    second_target = return_target(2, second_windows, second_tree)

    presentation =
      %Presentation{}
      |> Presentation.activate(first_windows, first_tree, first_target)
      |> Presentation.focus(:file_viewer)
      |> Presentation.install_prefix(:g)
      |> Presentation.activate(second_windows, second_tree, second_target)

    assert Presentation.active?(presentation)
    assert Presentation.current_focus(presentation) == :chat
    assert Presentation.pending_prefix(presentation) == nil
    assert Presentation.return_target(presentation) == second_target

    {completed, restored_windows, restored_tree} = Presentation.complete(presentation)

    refute Presentation.active?(completed)
    assert Presentation.return_target(completed) == nil
    assert restored_windows == second_windows
    assert restored_tree == second_tree
  end

  test "cancellation returns the saved layout and clears every activation-local field" do
    windows = %Windows{active: 1, next_id: 2}
    file_tree = %FileTree{visibility: :focused}
    target = return_target(1, windows, file_tree)

    presentation =
      %Presentation{}
      |> Presentation.activate(windows, file_tree, target)
      |> Presentation.focus(:file_viewer)
      |> Presentation.install_prefix(:bracket_next)

    {canceled, restored_windows, restored_tree} = Presentation.cancel(presentation)

    refute Presentation.active?(canceled)
    assert Presentation.current_focus(canceled) == :chat
    assert Presentation.pending_prefix(canceled) == nil
    assert Presentation.return_target(canceled) == nil
    assert restored_windows == windows
    assert restored_tree == file_tree
  end

  defp return_target(tab_id, windows, file_tree) do
    ReturnTarget.new(tab_id, nil, windows, file_tree, :editor, false)
  end
end
