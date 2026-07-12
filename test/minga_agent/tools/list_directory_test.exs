defmodule MingaAgent.Tools.ListDirectoryTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.ListDirectory

  describe "execute/1 errors" do
    test "returns an error for a nonexistent directory" do
      assert {:error, message} = ListDirectory.execute("/nonexistent/dir")
      assert message =~ "directory not found"
    end

    @tag :tmp_dir
    test "returns an error when the path is a file", %{tmp_dir: dir} do
      path = Path.join(dir, "file.txt")
      File.write!(path, "")

      assert {:error, message} = ListDirectory.execute(path)
      assert message =~ "is a file"
    end
  end
end
