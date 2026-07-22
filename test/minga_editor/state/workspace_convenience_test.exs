defmodule MingaEditor.State.WorkspaceConvenienceTest do
  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Mode.State, as: ModeState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.VimState

  defp workspace do
    %SessionState{}
  end

  test "workspace owner commits focused child transitions" do
    buffers = Buffers.add(%Buffers{}, self())
    search = Search.record(%Search{}, "needle", :forward)

    workspace =
      workspace()
      |> SessionState.set_keymap_scope(:file_tree)
      |> SessionState.set_buffers(buffers)
      |> SessionState.set_search(search)

    assert workspace.keymap_scope == :file_tree
    assert workspace.buffers == buffers
    assert workspace.search == search
  end

  test "vim owner commits mode-state and jump transitions" do
    mode_state = %ModeState{pending: :replace}
    updated_mode_state = %ModeState{mode_state | pending: {:find, :f}}

    editing =
      VimState.new()
      |> VimState.set_mode_state(mode_state)
      |> VimState.set_mode_state(updated_mode_state)
      |> VimState.set_last_jump_pos({2, 4})

    assert editing.mode_state.pending == {:find, :f}
    assert editing.last_jump_pos == {2, 4}
    assert editing.mode == :normal
  end

  test "workspace mode transition keeps keymap scope and editing mode coherent" do
    workspace = SessionState.transition_mode(workspace(), :insert, Mode.initial_state())

    assert workspace.editing.mode == :insert
    assert workspace.keymap_scope == :editor
  end
end
