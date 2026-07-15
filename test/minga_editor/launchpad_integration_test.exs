defmodule MingaEditor.LaunchpadIntegrationTest do
  @moduledoc """
  Thin integration coverage for entering the zero-buffer launchpad.

  Launchpad state transitions and activation behavior are covered directly by command and state tests.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Startup
  alias MingaEditor.State.Launchpad

  test "killing the last buffer enters the launchpad with zero buffers", %{tmp_dir: tmp} do
    {:ok, buffer} = BufferProcess.start_link(content: "only buffer")
    state = initial_state(buffer, tmp)

    state = BufferManagement.execute(state, :kill_buffer)

    assert state.workspace.buffers.active == nil
    assert state.workspace.buffers.list == []
    assert %Launchpad{} = state.workspace.launchpad

    assert MingaEditor.Session.State.active_window_struct(state.workspace).content ==
             {:empty, :semantic}
  end

  defp initial_state(buffer, tmp) do
    {:ok, options} = Options.start_link(name: nil)

    Startup.build_initial_state(
      port_manager: nil,
      options_server: options,
      buffer: buffer,
      width: 60,
      height: 20,
      editing_model: :vim,
      session_dir: Path.join(tmp, "empty-sessions")
    )
  end
end
