defmodule Minga.Buffer.RemoteStorageTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess

  @moduletag :tmp_dir

  test "remote storage reads file content through erpc", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "remote.txt")
    File.write!(path, "remote content")

    {:ok, pid} = BufferProcess.start_link(file_path: path, storage: {:remote, node(), path})

    assert BufferProcess.content(pid) == "remote content"
    assert BufferProcess.file_path(pid) == path
    assert BufferProcess.storage(pid) == {:remote, node(), path}
    refute BufferProcess.read_only?(pid)
  end

  test "remote storage saves local edits back through erpc", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "remote.txt")
    File.write!(path, "before")

    {:ok, pid} = BufferProcess.start_link(file_path: path, storage: {:remote, node(), path})

    :ok = BufferProcess.insert_text(pid, " after")
    assert BufferProcess.dirty?(pid)

    assert BufferProcess.save(pid) == :ok
    assert File.read!(path) == " afterbefore"
    refute BufferProcess.dirty?(pid)
  end

  test "remote storage rejects files over the remote read cap", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "huge.txt")
    File.write!(path, String.duplicate("x", 1_000_001))

    previous = Process.flag(:trap_exit, true)

    try do
      assert BufferProcess.start_link(file_path: path, storage: {:remote, node(), path}) ==
               {:error, :file_too_large}
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "remote storage reports erpc errors without crashing" do
    missing_node = :"missing_remote@127.0.0.1"
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:remote_unavailable, {:erpc, _reason}}} =
               BufferProcess.start_link(
                 file_path: "/tmp/missing.txt",
                 storage: {:remote, missing_node, "/tmp/missing.txt"}
               )
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "remote storage detects save conflicts against server changes", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "remote.txt")
    File.write!(path, "base")

    {:ok, pid} = BufferProcess.start_link(file_path: path, storage: {:remote, node(), path})

    :ok = BufferProcess.insert_text(pid, "local ")
    File.write!(path, "agent changed")

    assert BufferProcess.save(pid) == {:error, :file_changed}
    assert BufferProcess.dirty?(pid)
    assert File.read!(path) == "agent changed"
  end

  test "force save overwrites a remote conflict", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "remote.txt")
    File.write!(path, "base")

    {:ok, pid} = BufferProcess.start_link(file_path: path, storage: {:remote, node(), path})

    :ok = BufferProcess.insert_text(pid, "local ")
    File.write!(path, "agent changed")

    assert BufferProcess.force_save(pid) == :ok
    assert File.read!(path) == "local base"
    refute BufferProcess.dirty?(pid)
  end
end
