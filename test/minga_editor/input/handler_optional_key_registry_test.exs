defmodule MingaEditor.Input.HandlerOptionalKeyRegistryTest do
  # Mutates the global input handler registry in persistent_term.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.InputLaterKeyHandler
  alias Minga.Test.InputMouseOnlyHandler
  alias MingaEditor.Input
  alias MingaEditor.Input.Router
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.VimState

  setup do
    Input.reset_handlers()
    Input.register_handler(:builtin, InputLaterKeyHandler, priority: 1)

    on_exit(fn ->
      Input.reset_handlers()
    end)

    :ok
  end

  test "loaded mouse-only handlers pass key routing through to later handlers" do
    for source <- [:builtin, {:extension, :mouse_only_handler}] do
      Input.register_handler(source, InputMouseOnlyHandler, priority: 0)

      state = Router.route_key(base_state(), ?x, 0)

      assert state.later_key_handler == :consumed
      Input.unregister_source(source)
    end
  end

  test "missing handler modules raise before optional key callback fallback" do
    Input.register_handler(:builtin, MingaEditor.Input.DoesNotExist, priority: 0)

    assert_raise ArgumentError, fn ->
      Router.route_key(base_state(), ?x, 0)
    end
  end

  defp base_state do
    {:ok, buf} = BufferProcess.start_link(content: "hello\nworld")

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{
          active: buf,
          list: [buf],
          active_index: 0
        }
      },
      interaction: %MingaEditor.State.Interaction{}
    }
  end
end
