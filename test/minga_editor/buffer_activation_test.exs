defmodule MingaEditor.BufferActivationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Parser.Manager
  alias MingaEditor.BufferActivation
  alias MingaEditor.HighlightSync
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Buffers

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    name = Module.concat(__MODULE__, "Parser#{System.unique_integer([:positive])}")
    manager = start_supervised!({Manager, name: name, parser_path: "/missing/minga-parser"})
    %{manager: manager}
  end

  test "owner API switches buffers without notifying the shell" do
    state = base_state(content: "first")
    first_buffer = state.workspace.buffers.active
    second_buffer = start_supervised!({BufferProcess, content: "second"})
    buffers = Buffers.add(state.workspace.buffers, second_buffer)

    state =
      then(state, fn state ->
        %{state | workspace: SessionState.activate_buffer(state.workspace, buffers)}
      end)

    activated = BufferActivation.activate(state, 0, notify_shell?: false)

    assert activated.workspace.buffers.active == first_buffer
  end

  test "owner API restores parser presentation for an uncached activated buffer", %{
    manager: manager
  } do
    state = base_state(content: "first", filetype: :elixir, parser_manager: manager)

    second_buffer =
      start_supervised!({BufferProcess, content: "defmodule Second do\nend\n", filetype: :elixir})

    buffers = Buffers.add_background(state.workspace.buffers, second_buffer)

    state = %{state | workspace: SessionState.set_buffers(state.workspace, buffers)}

    assert Manager.buffer_id(second_buffer, manager) == nil

    activated = BufferActivation.activate(state, 1, notify_shell?: false)

    assert activated.workspace.buffers.active == second_buffer
    assert is_integer(Manager.buffer_id(second_buffer, manager))
    assert Map.has_key?(activated.parser.highlighting.highlights, second_buffer)
  end

  test "owner API touches cached parser presentation without re-registering", %{manager: manager} do
    state = base_state(content: "first", filetype: :elixir, parser_manager: manager)

    second_buffer =
      start_supervised!({BufferProcess, content: "defmodule Second do\nend\n", filetype: :elixir})

    buffers = Buffers.add_background(state.workspace.buffers, second_buffer)

    state =
      %{state | workspace: SessionState.set_buffers(state.workspace, buffers)}
      |> HighlightSync.setup_for_buffer_pid(second_buffer)

    id = Manager.buffer_id(second_buffer, manager)

    activated = BufferActivation.activate(state, 1, notify_shell?: false)

    assert activated.workspace.buffers.active == second_buffer
    assert Manager.buffer_id(second_buffer, manager) == id
    assert Map.has_key?(activated.parser.highlighting.highlights, second_buffer)
  end

  test "negative selections preserve leaf-owned wraparound behavior" do
    state = base_state(content: "first")
    first_buffer = state.workspace.buffers.active
    second_buffer = start_supervised!({BufferProcess, content: "second"})
    buffers = Buffers.add(state.workspace.buffers, second_buffer)

    state =
      then(state, fn state ->
        %{state | workspace: SessionState.activate_buffer(state.workspace, buffers)}
      end)

    activated = BufferActivation.activate(state, -2, notify_shell?: false)

    assert activated.workspace.buffers.active == first_buffer
    refute activated.workspace.buffers.active == second_buffer
  end
end
