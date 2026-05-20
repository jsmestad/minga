defmodule MingaEditor.State.KeymapServerThreadingTest do
  @moduledoc """
  Integration test that proves `EditorState.keymap_server` is honored end-to-end.

  Without this test, every other test in the keymap suite would still pass even
  if `EditorState.keymap_server/1` were stubbed to ignore the field and always
  return the default singleton — because all the other tests both bind on and
  resolve against the same server, picked from the process dictionary.

  Here we start two anonymous `KeymapActive` servers, point an `EditorState` at
  one of them, and assert that scope resolution through
  `EditorState.keymap_context/1` honors that choice rather than falling back to
  the singleton.
  """
  use ExUnit.Case, async: true

  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Scope
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias Minga.Mode

  defp build_state(keymap_server) do
    %EditorState{
      port_manager: self(),
      keymap_server: keymap_server,
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: %VimState{mode: :normal, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: nil, list: []},
        keymap_scope: :agent
      }
    }
  end

  test "EditorState.keymap_server flows through keymap_context to scope resolution" do
    server_a = start_supervised!({KeymapActive, name: nil}, id: :server_a)
    server_b = start_supervised!({KeymapActive, name: nil}, id: :server_b)

    # Same key, different commands per server.
    KeymapActive.bind(server_a, {:agent, :normal}, "~", :cmd_from_a, "From A")
    KeymapActive.bind(server_b, {:agent, :normal}, "~", :cmd_from_b, "From B")

    state_a = build_state(server_a)
    state_b = build_state(server_b)

    # The accessor returns the right server.
    assert EditorState.keymap_server(state_a) == server_a
    assert EditorState.keymap_server(state_b) == server_b

    # The keymap_context kw list carries the server.
    assert EditorState.keymap_context(state_a) == [keymap_server: server_a]
    assert EditorState.keymap_context(state_b) == [keymap_server: server_b]

    # End-to-end: scope resolution through the editor state's context honors
    # which server the state points at, even when both servers have a binding
    # for the same key.
    assert {:command, :cmd_from_a} =
             Scope.resolve_key(:agent, :normal, {?~, 0}, EditorState.keymap_context(state_a))

    assert {:command, :cmd_from_b} =
             Scope.resolve_key(:agent, :normal, {?~, 0}, EditorState.keymap_context(state_b))
  end

  test "EditorState defaults keymap_server to Minga.Keymap.default_server/0" do
    state = %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: %VimState{mode: :normal, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: nil, list: []}
      }
    }

    assert EditorState.keymap_server(state) == Minga.Keymap.default_server()
  end
end
