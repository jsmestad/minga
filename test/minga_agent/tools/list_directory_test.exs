defmodule MingaAgent.Tools.ListDirectoryTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.ListDirectory

  describe "execute/1 errors" do
    @tag :tmp_dir
    test "returns an error for a nonexistent directory, even if it would be ignored",
         %{tmp_dir: dir} do
      for name <- ["missing", "node_modules"] do
        assert {:error, message} = ListDirectory.execute(Path.join(dir, name))
        assert message =~ "directory not found"
      end
    end

    @tag :tmp_dir
    test "returns an error when the path is a file, even if it would be ignored",
         %{tmp_dir: dir} do
      for name <- ["file.txt", ".env.local"] do
        path = Path.join(dir, name)
        File.write!(path, "")

        assert {:error, message} = ListDirectory.execute(path)
        assert message =~ "is a file"
      end
    end
  end
end
