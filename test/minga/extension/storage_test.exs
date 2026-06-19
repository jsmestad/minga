defmodule Minga.Extension.StorageTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Storage

  @ext :storage_test_ext

  setup do
    # Sandbox the data root to a temp dir so tests never touch the real home.
    base =
      Path.join(System.tmp_dir!(), "minga_storage_test_#{System.unique_integer([:positive])}")

    Application.put_env(:minga, :extension_data_dir, base)

    on_exit(fn ->
      Application.delete_env(:minga, :extension_data_dir)
      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  test "write then read round-trips", %{base: base} do
    assert :ok = Storage.write(@ext, "graph.json", ~s({"a":1}))
    assert {:ok, ~s({"a":1})} = Storage.read(@ext, "graph.json")
    assert File.exists?(Path.join([base, Atom.to_string(@ext), "data", "graph.json"]))
  end

  test "write is atomic (no temp file left behind)", %{base: base} do
    assert :ok = Storage.write(@ext, "graph.json", "payload")
    data_dir = Path.join([base, Atom.to_string(@ext), "data"])
    refute File.exists?(Path.join(data_dir, "graph.json.tmp"))
  end

  test "write creates nested subdirectories" do
    assert :ok = Storage.write(@ext, "nested/dir/file.txt", "x")
    assert {:ok, "x"} = Storage.read(@ext, "nested/dir/file.txt")
  end

  test "path traversal is rejected" do
    assert {:error, :invalid_path} = Storage.write(@ext, "../escape.txt", "x")
    assert {:error, :invalid_path} = Storage.read(@ext, "../../etc/passwd")
  end

  test "reading a missing file returns posix error" do
    assert {:error, :enoent} = Storage.read(@ext, "does_not_exist.json")
  end
end
