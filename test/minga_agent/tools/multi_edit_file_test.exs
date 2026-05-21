defmodule MingaAgent.Tools.MultiEditFileTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools
  alias MingaAgent.Tools.MultiEditFile
  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess

  @moduletag :tmp_dir

  describe "execute/2" do
    test "applies multiple edits to a file", %{tmp_dir: dir} do
      path = Path.join(dir, "test.ex")

      File.write!(path, """
      defmodule Foo do
        def hello, do: :world
        def goodbye, do: :earth
      end
      """)

      edits = [
        %{"old_text" => "def hello, do: :world", "new_text" => "def hello, do: :universe"},
        %{"old_text" => "def goodbye, do: :earth", "new_text" => "def goodbye, do: :mars"}
      ]

      assert {:ok, result} = MultiEditFile.execute(path, edits)
      assert result =~ "2/2 edits applied"

      content = buffer_content(path)
      assert content =~ ":universe"
      assert content =~ ":mars"
    end

    test "reports partial failures without blocking other edits", %{tmp_dir: dir} do
      path = Path.join(dir, "test.ex")

      File.write!(path, """
      line one
      line two
      line three
      """)

      edits = [
        %{"old_text" => "line one", "new_text" => "LINE ONE"},
        %{"old_text" => "nonexistent text", "new_text" => "replacement"},
        %{"old_text" => "line three", "new_text" => "LINE THREE"}
      ]

      assert {:ok, result} = MultiEditFile.execute(path, edits)
      assert result =~ "2/3 edits applied"
      assert result =~ "1 failed"
      assert result =~ "old_text not found"

      content = buffer_content(path)
      assert content =~ "LINE ONE"
      assert content =~ "line two"
      assert content =~ "LINE THREE"
    end

    test "reports ambiguous matches as errors", %{tmp_dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "hello world hello world")

      edits = [
        %{"old_text" => "hello world", "new_text" => "goodbye"}
      ]

      assert {:ok, result} = MultiEditFile.execute(path, edits)
      assert result =~ "0/1 edits applied"
      assert result =~ "ambiguous"
    end

    test "handles empty old_text", %{tmp_dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "content")

      edits = [%{"old_text" => "", "new_text" => "something"}]

      assert {:ok, result} = MultiEditFile.execute(path, edits)
      assert result =~ "old_text is empty"
    end

    test "handles empty edits list", %{tmp_dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "content")

      assert {:ok, result} = MultiEditFile.execute(path, [])
      assert result =~ "0/0 edits applied"
    end

    test "returns error for missing file", %{tmp_dir: dir} do
      path = Path.join(dir, "nonexistent.txt")

      assert {:error, msg} =
               MultiEditFile.execute(path, [%{"old_text" => "a", "new_text" => "b"}])

      assert msg =~ "file not found"
    end

    test "edits are applied sequentially so earlier edits affect later ones", %{tmp_dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "foo bar baz")

      edits = [
        %{"old_text" => "foo", "new_text" => "bar"},
        %{"old_text" => "bar", "new_text" => "qux"}
      ]

      assert {:ok, result} = MultiEditFile.execute(path, edits)
      assert result =~ "1/2 edits applied"

      assert buffer_content(path) == "bar bar baz"
    end

    test "does not modify buffer content when all edits fail", %{tmp_dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "original content")

      edits = [
        %{"old_text" => "nonexistent", "new_text" => "replacement"}
      ]

      assert {:ok, _} = MultiEditFile.execute(path, edits)
      assert buffer_content(path) == "original content"
    end
  end

  describe "execute/2 via buffer (buffer open for file)" do
    test "batch edits route through buffer as a single undo entry", %{tmp_dir: dir} do
      path = Path.join(dir, "buffered.ex")
      File.write!(path, "aaa bbb ccc")
      pid = start_supervised!({BufferProcess, file_path: path})

      edits = [
        %{"old_text" => "aaa", "new_text" => "AAA"},
        %{"old_text" => "ccc", "new_text" => "CCC"}
      ]

      assert {:ok, result} = MultiEditFile.execute(path, edits)
      assert result =~ "2/2 edits applied"
      assert BufferProcess.content(pid) == "AAA bbb CCC"
      assert BufferProcess.dirty?(pid)
      assert File.read!(path) == "aaa bbb ccc"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "aaa bbb ccc"
    end

    test "ensure_for_path creates buffer when none exists", %{tmp_dir: dir} do
      path = Path.join(dir, "no_buffer.ex")
      File.write!(path, "aaa bbb")

      edits = [%{"old_text" => "aaa", "new_text" => "AAA"}]
      assert {:ok, _} = MultiEditFile.execute(path, edits)

      {:ok, pid} = Buffer.pid_for_path(Path.expand(path))
      assert BufferProcess.content(pid) == "AAA bbb"
      assert BufferProcess.dirty?(pid)
    end
  end

  describe "execute/2 via Tools when fork store routing is dead" do
    test "returns a routing error instead of falling back to direct filesystem edits", %{
      tmp_dir: dir
    } do
      root = Path.join(dir, "root")
      File.mkdir_p!(Path.join(root, "lib"))
      file = Path.join(root, "lib/unopened.txt")
      File.write!(file, "old text\n")

      {:ok, fork_store} = start_supervised(MingaAgent.BufferForkStore)
      Process.exit(fork_store, :kill)

      tools = Tools.all(project_root: root, fork_store: fork_store)

      assert {:error, message} =
               call_tool(tools, "multi_edit_file", %{
                 "path" => "lib/unopened.txt",
                 "edits" => [%{"old_text" => "old", "new_text" => "new"}]
               })

      assert message =~ "fork_unavailable"
      assert File.read!(file) == "old text\n"
    end
  end

  defp call_tool(tools, name, args) do
    tool = Enum.find(tools, &(&1.name == name))
    tool.callback.(args)
  end

  defp buffer_content(path) do
    {:ok, pid} = Buffer.pid_for_path(Path.expand(path))
    BufferProcess.content(pid)
  end
end
