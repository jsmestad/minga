defmodule MingaEditor.BufferActivationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.BufferActivation
  alias MingaEditor.Handlers.EffectHandler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers

  import MingaEditor.RenderPipeline.TestHelpers

  test "shell activation effects switch buffers without recursively notifying the shell" do
    state = base_state(content: "first")
    first_buffer = state.workspace.buffers.active
    second_buffer = start_supervised!({BufferProcess, content: "second"})
    buffers = Buffers.add(state.workspace.buffers, second_buffer)

    state =
      EditorState.set_workspace(state, SessionState.activate_buffer(state.workspace, buffers))

    activated =
      EffectHandler.apply_buffer_activation_effects(state, [{:switch_buffer, first_buffer}])

    assert activated.workspace.buffers.active == first_buffer
  end

  test "negative selections preserve leaf-owned wraparound behavior" do
    state = base_state(content: "first")
    first_buffer = state.workspace.buffers.active
    second_buffer = start_supervised!({BufferProcess, content: "second"})
    buffers = Buffers.add(state.workspace.buffers, second_buffer)

    state =
      EditorState.set_workspace(state, SessionState.activate_buffer(state.workspace, buffers))

    activated = BufferActivation.activate(state, -2, notify_shell?: false)

    assert activated.workspace.buffers.active == first_buffer
    refute activated.workspace.buffers.active == second_buffer
  end
end
