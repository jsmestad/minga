defmodule Minga.Agent.Tools.WriteFileTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.WriteFile
  alias Minga.Buffer.Server, as: BufferServer

  @moduletag :tmp_dir

  describe "execute/2" do
    test "writes content to a new file", %{tmp_dir: dir} do
      path = Path.join(dir, "new.txt")

      assert {:ok, msg} = WriteFile.execute(path, "hello")
      assert msg =~ "wrote 5 bytes"
      assert File.read!(path) == "hello"
    end

    test "overwrites an existing file", %{tmp_dir: dir} do
      path = Path.join(dir, "existing.txt")
      File.write!(path, "old content")

      assert {:ok, _} = WriteFile.execute(path, "new content")
      assert File.read!(path) == "new content"
    end

    test "creates parent directories", %{tmp_dir: dir} do
      path = Path.join([dir, "a", "b", "c", "deep.txt"])

      assert {:ok, _} = WriteFile.execute(path, "deep file")
      assert File.read!(path) == "deep file"
    end

    test "writes unicode content", %{tmp_dir: dir} do
      path = Path.join(dir, "unicode.txt")
      content = "Ελληνικά 日本語"

      assert {:ok, _} = WriteFile.execute(path, content)
      assert File.read!(path) == content
    end

    test "writes empty content", %{tmp_dir: dir} do
      path = Path.join(dir, "empty.txt")

      assert {:ok, msg} = WriteFile.execute(path, "")
      assert msg =~ "wrote 0 bytes"
      assert File.read!(path) == ""
    end
  end

  describe "execute/2 via buffer (buffer open for file)" do
    test "replaces buffer content when buffer is open", %{tmp_dir: dir} do
      path = Path.join(dir, "buffered.ex")
      File.write!(path, "old content")
      pid = start_supervised!({BufferServer, file_path: path})

      assert {:ok, msg} = WriteFile.execute(path, "new content")
      assert msg =~ "via buffer"

      # Edit went through buffer
      assert BufferServer.content(pid) == "new content"
      assert BufferServer.dirty?(pid)

      # Disk unchanged
      assert File.read!(path) == "old content"
    end

    test "write through buffer is undoable", %{tmp_dir: dir} do
      path = Path.join(dir, "undo.ex")
      File.write!(path, "original")
      pid = start_supervised!({BufferServer, file_path: path})

      WriteFile.execute(path, "replaced")
      assert BufferServer.content(pid) == "replaced"

      BufferServer.undo(pid)
      assert BufferServer.content(pid) == "original"
    end

    test "creates file on disk when no buffer is open", %{tmp_dir: dir} do
      path = Path.join(dir, "new_file.ex")

      assert {:ok, _} = WriteFile.execute(path, "brand new")
      assert File.read!(path) == "brand new"
    end
  end
end
