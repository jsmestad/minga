defmodule Minga.Agent.Tools.WriteFileTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.WriteFile

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
end
