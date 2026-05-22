defmodule MingaEditor.State.WorkspaceConvenienceTest do
  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Mode.State, as: ModeState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.Viewport

  defp editor_state do
    %EditorState{
      port_manager: nil,
      workspace: %SessionState{viewport: Viewport.new(24, 80)}
    }
  end

  test "workspace convenience setters route through the workspace owner" do
    buffers = %Buffers{list: [self()], active: self(), active_index: 0}
    search = Search.record(%Search{}, "needle", :forward)

    state =
      editor_state()
      |> EditorState.set_keymap_scope(:file_tree)
      |> EditorState.set_buffers(buffers)
      |> EditorState.set_search(search)

    assert state.workspace.keymap_scope == :file_tree
    assert state.workspace.buffers == buffers
    assert state.workspace.search == search
  end

  test "workspace convenience updaters apply mappers to the nested struct" do
    state =
      editor_state()
      |> EditorState.update_buffers(&Buffers.add(&1, self()))
      |> EditorState.update_search(&Search.record(&1, "needle", :forward))

    assert state.workspace.buffers.active == self()
    assert state.workspace.search.last_pattern == "needle"
  end

  test "vim convenience helpers update nested editing state" do
    mode_state = %ModeState{pending: :replace}

    state =
      editor_state()
      |> EditorState.set_mode_state(mode_state)
      |> EditorState.update_mode_state(&%{&1 | pending: {:find, :f}})
      |> EditorState.set_last_jump_pos({2, 4})

    assert state.workspace.editing.mode_state.pending == {:find, :f}
    assert state.workspace.editing.last_jump_pos == {2, 4}
    assert state.workspace.editing.mode == :normal
  end

  test "transition_mode remains available for mode changes" do
    state = EditorState.transition_mode(editor_state(), :insert, Mode.initial_state())

    assert state.workspace.editing.mode == :insert
  end
end
