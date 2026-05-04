defmodule MingaEditor.State.OptionsServerThreadingTest do
  @moduledoc """
  Integration test that proves `EditorState.options_server` is honored end-to-end.

  Without this test, every other test in the options suite would still pass even
  if `EditorState.options_server/1` were stubbed to ignore the field and always
  return the default singleton — because all other tests both write to and read
  from the same server, picked from the process dictionary.

  Here we start two anonymous `Config.Options` servers, point an `EditorState`
  at one of them, and assert that reads through `EditorState.options_server/1`
  honor that choice rather than falling back to the singleton.
  """
  use ExUnit.Case, async: true

  alias Minga.Config.Options
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias Minga.Mode

  defp build_state(options_server) do
    %EditorState{
      port_manager: self(),
      options_server: options_server,
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        editing: %VimState{mode: :normal, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: nil, list: []},
        keymap_scope: :editor
      }
    }
  end

  test "EditorState.options_server isolates writes between distinct servers" do
    server_a = start_supervised!({Options, name: nil}, id: :options_a)
    server_b = start_supervised!({Options, name: nil}, id: :options_b)

    # Same option key, different values per server.
    {:ok, _} = Options.set(server_a, :tab_width, 4)
    {:ok, _} = Options.set(server_b, :tab_width, 8)

    state_a = build_state(server_a)
    state_b = build_state(server_b)

    # The accessor returns the right server.
    assert EditorState.options_server(state_a) == server_a
    assert EditorState.options_server(state_b) == server_b

    # End-to-end: option reads through the editor state's server honor which
    # server the state points at, even when both have written to the same key.
    assert Options.get(EditorState.options_server(state_a), :tab_width) == 4
    assert Options.get(EditorState.options_server(state_b), :tab_width) == 8
  end

  test "EditorState defaults options_server to Minga.Config.Options.default_server/0" do
    state = %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        editing: %VimState{mode: :normal, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: nil, list: []}
      }
    }

    assert EditorState.options_server(state) == Options.default_server()
  end
end
