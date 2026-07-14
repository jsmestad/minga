defmodule MingaEditor.BufferActivationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.BufferActivation
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Buffers

  import MingaEditor.RenderPipeline.TestHelpers

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
