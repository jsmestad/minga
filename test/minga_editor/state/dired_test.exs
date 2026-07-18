defmodule MingaEditor.State.DiredTest do
  use ExUnit.Case, async: true

  alias Minga.Dired
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Dired, as: DiredState
  alias MingaEditor.Viewport

  test "Dired backing retirement is exact and normalizes only stale Dired scope" do
    dired_pid = self()
    other_pid = Process.whereis(:code_server)
    dired = DiredState.activate(%DiredState{}, %Dired{directory: "/tmp"}, dired_pid)
    base = %SessionState{viewport: Viewport.new(24, 80), dired: dired}
    single = %Buffers{active: dired_pid, list: [dired_pid]}
    assert DiredState.retire_buffer(dired, dired_pid) == %DiredState{}
    assert DiredState.retire_buffer(dired, other_pid) == dired

    editor =
      SessionState.retire_dired_buffer(%{base | keymap_scope: :dired, buffers: single}, dired_pid)

    agent =
      SessionState.retire_dired_buffer(%{base | keymap_scope: :agent, buffers: single}, dired_pid)

    assert editor.dired == %DiredState{}
    assert editor.keymap_scope == :editor
    assert agent.dired == %DiredState{}
    assert agent.keymap_scope == :agent
    buffers = %Buffers{active: dired_pid, list: [dired_pid, other_pid]}
    root = fn -> %EditorState{workspace: %{base | keymap_scope: :dired, buffers: buffers}} end
    exact = EditorState.remove_buffer(root.(), dired_pid)
    unrelated = EditorState.remove_buffer(root.(), other_pid)
    assert exact.workspace.dired == %DiredState{}
    assert exact.workspace.keymap_scope == :editor
    refute dired_pid in exact.workspace.buffers.list
    assert unrelated.workspace.dired == dired
    assert unrelated.workspace.keymap_scope == :dired
    assert dired_pid in unrelated.workspace.buffers.list
    refute other_pid in unrelated.workspace.buffers.list
  end
end
