defmodule Minga.Distribution.FileTest do
  use ExUnit.Case, async: true

  alias Minga.Distribution.File, as: RemoteFile

  test "read/2 reads from the current node" do
    path = temp_file("hello.txt", "hello")
    assert RemoteFile.read(node(), path) == {:ok, "hello"}
  end

  test "list_local_files/1 returns supported text files and skips build dirs" do
    dir = temp_dir()
    File.write!(Path.join(dir, "a.ex"), "defmodule A do end")
    File.write!(Path.join(dir, "image.png"), <<0, 1, 2>>)
    File.mkdir_p!(Path.join(dir, "_build"))
    File.write!(Path.join([dir, "_build", "ignored.ex"]), "ignored")

    assert {:ok, paths} = RemoteFile.list_local_files(dir)
    assert Path.join(dir, "a.ex") in paths
    refute Path.join(dir, "image.png") in paths
    refute Path.join([dir, "_build", "ignored.ex"]) in paths
  end

  test "read/3 rejects files over the size cap" do
    path = temp_file("large.txt", "hello")
    assert RemoteFile.read(node(), path, max_bytes: 2) == {:error, :file_too_large}
  end

  test "list_local_files/3 caps result count and depth" do
    dir = temp_dir()
    nested = Path.join(dir, "nested")
    File.mkdir_p!(nested)
    File.write!(Path.join(dir, "a.ex"), "a")
    File.write!(Path.join(dir, "b.ex"), "b")
    File.write!(Path.join(nested, "c.ex"), "c")

    assert {:ok, one_path} = RemoteFile.list_local_files(dir, 1, 12)
    assert length(one_path) == 1

    assert {:ok, shallow_paths} = RemoteFile.list_local_files(dir, 10, 0)
    refute Path.join(nested, "c.ex") in shallow_paths
  end

  @spec temp_file(String.t(), String.t()) :: String.t()
  defp temp_file(name, content) do
    dir = temp_dir()
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  @spec temp_dir() :: String.t()
  defp temp_dir do
    dir =
      Path.join(System.tmp_dir!(), "minga-remote-file-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    dir
  end
end
