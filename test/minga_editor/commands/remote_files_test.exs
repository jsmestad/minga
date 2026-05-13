defmodule MingaEditor.Commands.RemoteFilesTest do
  use Minga.Test.EditorCase, async: true

  alias MingaEditor.Commands.RemoteFiles

  test "find_remote_file/1 reports when no remote server is connected" do
    ctx = start_editor("initial")

    state =
      ctx
      |> editor_state()
      |> RemoteFiles.find_remote_file()

    assert state.shell_state.status_msg == "No connected remote servers"
  end

  test "open_remote_file/3 reports unknown server" do
    ctx = start_editor("initial")

    state =
      ctx
      |> editor_state()
      |> RemoteFiles.open_remote_file("missing", "/tmp/file.ex")

    assert state.shell_state.status_msg == "Unknown remote server missing"
  end
end
