defmodule MingaAgent.Tools.EditFileTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.EditFile
  alias Minga.Buffer
  alias Minga.Buffer.Server, as: BufferServer

  @moduletag :tmp_dir

  describe "execute/3" do
    test "replaces exact text in a file", %{tmp_dir: dir} do
      path = Path.join(dir, "code.ex")
      File.write!(path, "defmodule Foo do\n  def hello, do: :world\nend\n")

      assert {:ok, _} = EditFile.execute(path, "def hello, do: :world", "def hello, do: :earth")
      assert buffer_content(path) == "defmodule Foo do\n  def hello, do: :earth\nend\n"
    end

    test "returns error when old_text is not found", %{tmp_dir: dir} do
      path = Path.join(dir, "code.ex")
      File.write!(path, "defmodule Foo do\nend\n")

      assert {:error, msg} = EditFile.execute(path, "nonexistent text", "replacement")
      assert msg =~ "old_text not found"
    end

    test "returns error when old_text appears multiple times", %{tmp_dir: dir} do
      path = Path.join(dir, "code.ex")
      File.write!(path, "foo\nbar\nfoo\n")

      assert {:error, msg} = EditFile.execute(path, "foo", "baz")
      assert msg =~ "found 2 times"
    end

    test "returns error for missing file" do
      assert {:error, msg} = EditFile.execute("/nonexistent/file.txt", "old", "new")
      assert msg =~ "file not found"
    end

    test "handles multi-line replacements", %{tmp_dir: dir} do
      path = Path.join(dir, "multi.txt")
      File.write!(path, "line1\nline2\nline3\n")

      assert {:ok, _} = EditFile.execute(path, "line1\nline2", "replaced1\nreplaced2")
      assert buffer_content(path) == "replaced1\nreplaced2\nline3\n"
    end

    test "preserves whitespace-sensitive content", %{tmp_dir: dir} do
      path = Path.join(dir, "indent.py")
      content = "def foo():\n    if True:\n        pass\n"
      File.write!(path, content)

      assert {:ok, _} = EditFile.execute(path, "        pass", "        return 42")
      assert buffer_content(path) == "def foo():\n    if True:\n        return 42\n"
    end
  end

  describe "execute/3 via buffer (buffer open for file)" do
    test "routes through buffer when buffer is open", %{tmp_dir: dir} do
      path = Path.join(dir, "buffered.ex")
      File.write!(path, "defmodule Foo do\n  def hello, do: :world\nend\n")
      pid = start_supervised!({BufferServer, file_path: path})

      assert {:ok, _} = EditFile.execute(path, "def hello, do: :world", "def hello, do: :earth")

      # Edit went through buffer, not disk
      assert BufferServer.content(pid) =~ "def hello, do: :earth"
      assert BufferServer.dirty?(pid)

      # Disk file unchanged
      assert File.read!(path) =~ "def hello, do: :world"
    end

    test "edit through buffer is undoable", %{tmp_dir: dir} do
      path = Path.join(dir, "undo.ex")
      File.write!(path, "aaa bbb ccc")
      pid = start_supervised!({BufferServer, file_path: path})

      EditFile.execute(path, "bbb", "BBB")
      assert BufferServer.content(pid) == "aaa BBB ccc"

      BufferServer.undo(pid)
      assert BufferServer.content(pid) == "aaa bbb ccc"
    end

    test "return value contract is identical for both paths", %{tmp_dir: dir} do
      # Buffer path (ensure_for_path creates a buffer)
      path1 = Path.join(dir, "first.ex")
      File.write!(path1, "hello world")
      assert {:ok, msg1} = EditFile.execute(path1, "hello", "goodbye")
      assert is_binary(msg1)

      # Pre-opened buffer path
      path2 = Path.join(dir, "second.ex")
      File.write!(path2, "hello world")
      _pid = start_supervised!({BufferServer, file_path: path2})
      assert {:ok, msg2} = EditFile.execute(path2, "hello", "goodbye")
      assert is_binary(msg2)
    end

    test "ensure_for_path creates buffer when none exists", %{tmp_dir: dir} do
      path = Path.join(dir, "no_buffer.ex")
      File.write!(path, "hello world")

      assert {:ok, _} = EditFile.execute(path, "hello", "goodbye")

      # Buffer was created by ensure_for_path; edit went through buffer
      {:ok, pid} = Buffer.pid_for_path(Path.expand(path))
      assert BufferServer.content(pid) == "goodbye world"
      assert BufferServer.dirty?(pid)
    end
  end

  # Helper to read content from the buffer that ensure_for_path created.
  defp buffer_content(path) do
    {:ok, pid} = Buffer.pid_for_path(Path.expand(path))
    BufferServer.content(pid)
  end
end
