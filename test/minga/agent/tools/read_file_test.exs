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
end
