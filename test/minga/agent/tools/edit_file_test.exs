defmodule Minga.Agent.Tools.EditFileTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.EditFile
  alias Minga.Buffer.Server, as: BufferServer

  @moduletag :tmp_dir

  describe "execute/3" do
    test "replaces exact text in a file", %{tmp_dir: dir} do
      path = Path.join(dir, "code.ex")
      File.write!(path, "defmodule Foo do\n  def hello, do: :world\nend\n")

      assert {:ok, _} = EditFile.execute(path, "def hello, do: :world", "def hello, do: :earth")
      assert File.read!(path) == "defmodule Foo do\n  def hello, do: :earth\nend\n"
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
      assert File.read!(path) == "replaced1\nreplaced2\nline3\n"
    end

    test "preserves whitespace-sensitive content", %{tmp_dir: dir} do
      path = Path.join(dir, "indent.py")
      content = "def foo():\n    if True:\n        pass\n"
      File.write!(path, content)

      assert {:ok, _} = EditFile.execute(path, "        pass", "        return 42")
      assert File.read!(path) == "def foo():\n    if True:\n        return 42\n"
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
      # Filesystem path
      fs_path = Path.join(dir, "fs.ex")
      File.write!(fs_path, "hello world")
      assert {:ok, fs_msg} = EditFile.execute(fs_path, "hello", "goodbye")
      assert is_binary(fs_msg)

      # Buffer path
      buf_path = Path.join(dir, "buf.ex")
      File.write!(buf_path, "hello world")
      _pid = start_supervised!({BufferServer, file_path: buf_path})
      assert {:ok, buf_msg} = EditFile.execute(buf_path, "hello", "goodbye")
      assert is_binary(buf_msg)
    end

    test "falls back to filesystem when no buffer is open", %{tmp_dir: dir} do
      path = Path.join(dir, "no_buffer.ex")
      File.write!(path, "hello world")

      assert {:ok, _} = EditFile.execute(path, "hello", "goodbye")
      assert File.read!(path) == "goodbye world"
    end
  end
end
