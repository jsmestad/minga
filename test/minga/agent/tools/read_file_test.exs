defmodule Minga.Agent.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.ReadFile
  alias Minga.Buffer

  @moduletag :tmp_dir

  describe "execute/1" do
    test "reads a text file", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.txt")
      File.write!(path, "hello world")

      assert {:ok, "hello world"} = ReadFile.execute(path)
    end

    test "reads a file with unicode content", %{tmp_dir: dir} do
      path = Path.join(dir, "unicode.txt")
      content = "こんにちは世界 🌍"
      File.write!(path, content)

      assert {:ok, ^content} = ReadFile.execute(path)
    end

    test "returns error for missing file" do
      assert {:error, msg} = ReadFile.execute("/nonexistent/path/file.txt")
      assert msg =~ "file not found"
    end

    test "returns error for a directory", %{tmp_dir: dir} do
      assert {:error, msg} = ReadFile.execute(dir)
      assert msg =~ "is a directory"
    end

    test "returns error for binary files", %{tmp_dir: dir} do
      path = Path.join(dir, "binary.bin")
      # Write invalid UTF-8 bytes
      File.write!(path, <<0xFF, 0xFE, 0x00, 0x01>>)

      assert {:error, msg} = ReadFile.execute(path)
      assert msg =~ "binary file"
    end

    test "truncates large files", %{tmp_dir: dir} do
      path = Path.join(dir, "large.txt")
      # 300KB of text
      content = String.duplicate("x", 300_000)
      File.write!(path, content)

      assert {:ok, result} = ReadFile.execute(path)
      assert result =~ "[truncated at 256KB]"
      assert byte_size(result) < 300_000
    end

    test "reads empty files", %{tmp_dir: dir} do
      path = Path.join(dir, "empty.txt")
      File.write!(path, "")

      assert {:ok, ""} = ReadFile.execute(path)
    end
  end

  describe "execute/2 with offset and limit" do
    setup %{tmp_dir: dir} do
      path = Path.join(dir, "lines.txt")
      lines = Enum.map_join(1..100, "\n", &"line #{&1}")
      File.write!(path, lines)
      %{path: path}
    end

    test "reads a slice with offset and limit", %{path: path} do
      assert {:ok, result} = ReadFile.execute(path, offset: 10, limit: 5)
      assert result =~ "[lines 10-14 of 100]"
      assert result =~ "line 10"
      assert result =~ "line 14"
      refute result =~ "line 9\n"
      refute result =~ "line 15"
    end

    test "reads from offset to end when limit is omitted", %{path: path} do
      assert {:ok, result} = ReadFile.execute(path, offset: 95)
      assert result =~ "[lines 95-100 of 100]"
      assert result =~ "line 95"
      assert result =~ "line 100"
    end

    test "reads first N lines when only limit is given", %{path: path} do
      assert {:ok, result} = ReadFile.execute(path, limit: 3)
      assert result =~ "[lines 1-3 of 100]"
      assert result =~ "line 1"
      assert result =~ "line 3"
      refute result =~ "line 4\n"
    end

    test "offset beyond file length returns clear message", %{path: path} do
      assert {:ok, result} = ReadFile.execute(path, offset: 200)
      assert result =~ "offset 200 is beyond end of file (100 lines)"
    end

    test "full file is returned when no offset/limit", %{path: path} do
      assert {:ok, result} = ReadFile.execute(path)
      # Should NOT have the header when no offset/limit
      refute result =~ "[lines"
      assert result =~ "line 1"
      assert result =~ "line 100"
    end

    test "offset 1 with limit returns from the beginning", %{path: path} do
      assert {:ok, result} = ReadFile.execute(path, offset: 1, limit: 2)
      assert result =~ "[lines 1-2 of 100]"
      assert result =~ "line 1"
      assert result =~ "line 2"
    end
  end

  describe "buffer-first routing" do
    test "returns in-memory buffer content instead of disk content", %{tmp_dir: dir} do
      path = Path.join(dir, "buffered.txt")
      File.write!(path, "disk content")

      # Start a buffer for the file, which registers in the Buffer.Registry
      {:ok, pid} = start_supervised({Buffer.Server, file_path: path})

      # Modify the buffer in-memory without saving to disk
      :ok = Buffer.Server.insert_text(pid, " MODIFIED")

      # ReadFile should return the in-memory content, not the disk content
      assert {:ok, result} = ReadFile.execute(path)
      assert result =~ "MODIFIED"
      refute result == "disk content"

      # Disk should still have the original content
      assert File.read!(path) == "disk content"
    end

    test "buffer routing works with offset and limit", %{tmp_dir: dir} do
      path = Path.join(dir, "buffered_lines.txt")
      disk_lines = Enum.map_join(1..10, "\n", &"disk line #{&1}")
      File.write!(path, disk_lines)

      {:ok, pid} = start_supervised({Buffer.Server, file_path: path})

      # Replace content in buffer with different lines
      :ok = Buffer.Server.replace_content(pid, Enum.map_join(1..10, "\n", &"buffer line #{&1}"))

      assert {:ok, result} = ReadFile.execute(path, offset: 3, limit: 2)
      assert result =~ "[lines 3-4 of 10]"
      assert result =~ "buffer line 3"
      assert result =~ "buffer line 4"
      refute result =~ "disk line"
    end

    test "falls back to disk when no buffer is open", %{tmp_dir: dir} do
      path = Path.join(dir, "no_buffer.txt")
      File.write!(path, "disk only content")

      # No buffer started, should read from disk
      assert {:ok, "disk only content"} = ReadFile.execute(path)
    end

    test "truncates large buffer content", %{tmp_dir: dir} do
      path = Path.join(dir, "large_buffer.txt")
      File.write!(path, "small")

      {:ok, pid} = start_supervised({Buffer.Server, file_path: path})

      # Replace with large content in buffer
      large_content = String.duplicate("x", 300_000)
      :ok = Buffer.Server.replace_content(pid, large_content)

      assert {:ok, result} = ReadFile.execute(path)
      assert result =~ "[truncated at 256KB]"
    end

    test "works with expanded paths", %{tmp_dir: dir} do
      path = Path.join(dir, "expanded.txt")
      File.write!(path, "disk content")

      {:ok, pid} = start_supervised({Buffer.Server, file_path: path})
      :ok = Buffer.Server.replace_content(pid, "buffer content")

      # ReadFile expands the path, so relative/absolute should both work
      assert {:ok, "buffer content"} = ReadFile.execute(path)
    end
  end

  describe "EditDelta tree-sitter sync" do
    test "find_and_replace broadcasts buffer_changed event", %{tmp_dir: dir} do
      path = Path.join(dir, "delta.txt")
      File.write!(path, "hello world")

      {:ok, pid} = start_supervised({Buffer.Server, file_path: path})

      # Subscribe to buffer change events
      Minga.Events.subscribe(:buffer_changed)

      # Apply an agent edit via find_and_replace (same path as agent tools)
      {:ok, _msg} = Buffer.Server.find_and_replace(pid, "hello", "goodbye")

      # The buffer should broadcast a :buffer_changed event that the parser
      # would use for tree-sitter incremental updates
      assert_receive {:minga_event, :buffer_changed, %{buffer: ^pid, version: version}},
                     1_000

      assert is_integer(version)

      # Verify the content was actually changed
      assert Buffer.Server.content(pid) =~ "goodbye world"
    end
  end
end
