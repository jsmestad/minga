defmodule Minga.Agent.Tools.MultiEditFileTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.MultiEditFile
  alias Minga.Buffer.Server, as: BufferServer

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

      content = File.read!(path)
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

      content = File.read!(path)
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

      # First edit changes "foo" to "bar", making "bar" appear twice.
      # Second edit tries to change "bar" and should fail due to ambiguity.
      edits = [
        %{"old_text" => "foo", "new_text" => "bar"},
        %{"old_text" => "bar", "new_text" => "qux"}
      ]

      assert {:ok, result} = MultiEditFile.execute(path, edits)
      assert result =~ "1/2 edits applied"

      content = File.read!(path)
      # "foo" was replaced with "bar", but "bar" is now ambiguous
      assert content == "bar bar baz"
    end

    test "does not write file when all edits fail", %{tmp_dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "original content")

      edits = [
        %{"old_text" => "nonexistent", "new_text" => "replacement"}
      ]

      assert {:ok, _} = MultiEditFile.execute(path, edits)

      # File should not have been rewritten
      assert File.read!(path) == "original content"
    end
  end

  describe "execute/2 via buffer (buffer open for file)" do
    test "batch edits route through buffer as a single undo entry", %{tmp_dir: dir} do
      path = Path.join(dir, "buffered.ex")
      File.write!(path, "aaa bbb ccc")
      pid = start_supervised!({BufferServer, file_path: path})

      edits = [
        %{"old_text" => "aaa", "new_text" => "AAA"},
        %{"old_text" => "ccc", "new_text" => "CCC"}
      ]

      assert {:ok, result} = MultiEditFile.execute(path, edits)
      assert result =~ "2/2 edits applied"

      # Edit went through buffer
      assert BufferServer.content(pid) == "AAA bbb CCC"
      assert BufferServer.dirty?(pid)

      # Disk unchanged
      assert File.read!(path) == "aaa bbb ccc"

      # Single undo reverts entire batch
      BufferServer.undo(pid)
      assert BufferServer.content(pid) == "aaa bbb ccc"
    end

    test "falls back to filesystem when no buffer is open", %{tmp_dir: dir} do
      path = Path.join(dir, "no_buffer.ex")
      File.write!(path, "aaa bbb")

      edits = [%{"old_text" => "aaa", "new_text" => "AAA"}]
      assert {:ok, _} = MultiEditFile.execute(path, edits)
      assert File.read!(path) == "AAA bbb"
    end
  end
end
