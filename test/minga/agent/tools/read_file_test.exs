defmodule Minga.Agent.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.ReadFile

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
end
