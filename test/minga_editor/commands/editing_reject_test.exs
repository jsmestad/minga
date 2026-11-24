defmodule MingaEditor.Commands.EditingRejectTest do
  @moduledoc """
  `SPC a u` wiring: the command accepts every outcome the buffer returns, including a refusal.
  """

  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Editing

  test "a task your visible edit holds is refused without changing the buffer" do
    buffer = start_buffer("xay\n")
    replace(buffer, {0, 1}, 1, "bcd", EditSource.minga("t", "s1"))
    replace(buffer, {0, 2}, 1, "QR", EditSource.user())
    replace(buffer, {0, 3}, 1, "Z", EditSource.minga("t", "s2"))
    content = BufferProcess.content(buffer)

    _state = Editing.execute(command_state(buffer), :undo_agent_session)

    assert BufferProcess.content(buffer) == content
    assert BufferProcess.undo_agent_session(buffer) == {:blocked, {:overlaps, :you}}
  end

  defp replace(buffer, position, length, text, source) do
    {:ok, _version} =
      BufferProcess.replace_byte_range_if_version(
        buffer,
        BufferProcess.version(buffer),
        position,
        length,
        text,
        source
      )
  end
end
