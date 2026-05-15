defmodule Minga.Buffer.PersistenceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Buffer.Persistence
  alias Minga.Buffer.State, as: BufState

  @moduletag :tmp_dir

  test "load_content returns scratch content when no file path is set" do
    assert Persistence.load_content(:local, nil, "scratch") == {:ok, "scratch", nil, {nil, nil}}
  end

  test "load_content treats missing files as new empty buffers", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "missing.txt")

    assert Persistence.load_content(:local, path, "ignored") == {:ok, "", path, {nil, nil}}
  end

  test "write creates parent directories and read returns the written content", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join([tmp_dir, "nested", "dir", "file.txt"])
    state = %BufState{document: Document.new(""), storage: :local}

    assert Persistence.write_content(state, path, "hello") == :ok
    assert Persistence.read_content(state, path) == {:ok, "hello"}
    assert {_mtime, 5} = Persistence.file_metadata(state, path)
  end

  test "changed_since_saved? ignores metadata drift when saved content still matches", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "same.txt")
    File.write!(path, "base")
    {mtime, size} = Persistence.file_metadata(:local, path)

    state = saved_state(path, "base", mtime, size)

    assert Persistence.changed_since_saved?(state, mtime + 10, size) == false
  end

  test "changed_since_saved? detects same-size content drift", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "changed.txt")
    File.write!(path, "base")
    {mtime, size} = Persistence.file_metadata(:local, path)

    state = saved_state(path, "base", mtime, size)
    File.write!(path, "diff")

    assert Persistence.changed_since_saved?(state, mtime, size) == true
  end

  defp saved_state(path, content, mtime, size) do
    %BufState{
      document: Document.new(content),
      file_path: path,
      mtime: mtime,
      file_size: size,
      file_hash: Persistence.content_fingerprint(content)
    }
  end
end
