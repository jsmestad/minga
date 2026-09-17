defmodule Minga.Git.BufferTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Git
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Git.Stub, as: GitStub

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    GitStub.ensure_table()
    GitStub.set_root(dir, dir)
    GitStub.set_head(dir, "conflict.txt", "base")

    on_exit(fn -> GitStub.clear(dir) end)

    %{root: dir, file_path: Path.join(dir, "conflict.txt")}
  end

  test "does not retain duplicate conflict regions", %{
    root: root,
    file_path: file_path
  } do
    {:ok, pid} =
      start_supervised(
        {GitBuffer, git_root: root, file_path: file_path, initial_content: conflict_content()}
      )

    refute Map.has_key?(:sys.get_state(pid), :conflicts)
  end

  test "sync_tracked_buffer returns after diff state is updated", %{
    root: root,
    file_path: file_path
  } do
    {:ok, git_pid} =
      start_supervised({GitBuffer, git_root: root, file_path: file_path, initial_content: "base"})

    buffer = start_supervised!({BufferProcess, content: "base"})
    Minga.Git.Tracker.put_mapping(buffer, git_pid)
    on_exit(fn -> Minga.Git.Tracker.remove_mapping(buffer) end)

    :ok = :sys.suspend(git_pid)
    sync = Task.async(fn -> Git.sync_tracked_buffer(buffer, "changed") end)
    refute Task.yield(sync, 50)

    :ok = :sys.resume(git_pid)
    assert Task.await(sync) == :ok
  end

  defp conflict_content do
    "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch"
  end
end
