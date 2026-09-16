defmodule MingaEditor.Commands.BufferManagementSaveTransformTest do
  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.BufferManagement

  @moduletag :tmp_dir

  test "ordinary save uses the active buffer's whitespace options", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "editor-save-crlf.txt")
    File.write!(path, "alpha  \r\nbeta")
    buffer = start_file_buffer(path)
    assert {:ok, _previous} = BufferProcess.set_option(buffer, :trim_trailing_whitespace, true)
    assert {:ok, _previous} = BufferProcess.set_option(buffer, :insert_final_newline, true)

    state = command_state(buffer)
    assert %{workspace: %{buffers: %{active: ^buffer}}} = BufferManagement.execute(state, :save)

    assert BufferProcess.content(buffer) == "alpha\r\nbeta\r\n"
    assert File.read!(path) == "alpha\r\nbeta\r\n"
  end

  @spec start_file_buffer(String.t()) :: pid()
  defp start_file_buffer(path) do
    start_supervised!({BufferProcess, file_path: path}, id: {BufferProcess, make_ref()})
  end
end
