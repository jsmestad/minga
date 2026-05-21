defmodule MingaAgent.Tools.DeleteFileTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.Events.FileWrittenEvent
  alias MingaAgent.Tools.DeleteFile

  @moduletag :tmp_dir

  describe "execute/1" do
    test "deletes files and broadcasts a deleted file_written event", %{tmp_dir: dir} do
      path = Path.join(dir, "delete-me.txt")
      File.write!(path, "gone soon")

      Events.subscribe(:file_written)

      assert {:ok, msg} = DeleteFile.execute(path)
      assert msg =~ "deleted #{path}"
      refute File.exists?(path)

      assert_receive {:minga_event, :file_written,
                      %FileWrittenEvent{path: ^path, change_type: :deleted}}
    end

    test "refuses to delete an open buffered file", %{tmp_dir: dir} do
      path = Path.join(dir, "buffered.txt")
      File.write!(path, "live buffer")
      pid = start_supervised!({BufferProcess, file_path: path})

      assert {:error, msg} = DeleteFile.execute(path)
      assert msg =~ "open buffer"
      assert File.exists?(path)
      assert BufferProcess.content(pid) == "live buffer"
    end
  end
end
