defmodule Minga.Agent.Tools.EditFileTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.EditFile

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
end
