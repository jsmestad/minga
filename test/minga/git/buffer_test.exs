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

  test "caches parsed merge conflicts on init", %{root: root, file_path: file_path} do
    {:ok, pid} =
      start_supervised(
        {GitBuffer, git_root: root, file_path: file_path, initial_content: conflict_content()}
      )

    assert GitBuffer.conflict_count(pid) == 1
    assert [region] = GitBuffer.conflicts(pid)
    assert region.current_lines == ["ours"]
    assert region.incoming_lines == ["theirs"]
  end

  test "updates cached conflicts when buffer content changes", %{root: root, file_path: file_path} do
    {:ok, pid} =
      start_supervised(
        {GitBuffer, git_root: root, file_path: file_path, initial_content: conflict_content()}
      )

    GitBuffer.update(pid, "resolved")
    :sys.get_state(pid)

    assert GitBuffer.conflicts(pid) == []
    assert GitBuffer.conflict_count(pid) == 0
  end

  test "sync_tracked_buffer updates tracked conflicts through the public facade", %{
    root: root,
    file_path: file_path
  } do
    {:ok, pid} =
      start_supervised(
        {GitBuffer, git_root: root, file_path: file_path, initial_content: conflict_content()}
      )

    buffer = start_supervised!({BufferProcess, [content: conflict_content()]})
    register_tracked_buffer(buffer, pid)

    assert :ok = Git.sync_tracked_buffer(buffer, "resolved")
    assert Git.conflicts(pid) == []
    assert Git.conflict_count(pid) == 0
  end

  test "updates cached conflicts when the base is invalidated", %{
    root: root,
    file_path: file_path
  } do
    {:ok, pid} =
      start_supervised(
        {GitBuffer, git_root: root, file_path: file_path, initial_content: conflict_content()}
      )

    GitBuffer.invalidate_base(pid, "resolved")
    :sys.get_state(pid)

    assert GitBuffer.conflicts(pid) == []
    assert GitBuffer.conflict_count(pid) == 0
  end

  test "public Git facade exposes cached conflict regions", %{root: root, file_path: file_path} do
    {:ok, pid} =
      start_supervised(
        {GitBuffer, git_root: root, file_path: file_path, initial_content: conflict_content()}
      )

    assert Git.conflict_count(pid) == 1
    assert [_region] = Git.conflicts(pid)
  end

  defp register_tracked_buffer(buffer, git_pid) do
    table = Minga.Git.Tracker.Registry

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ets.insert(table, {buffer, git_pid})
    on_exit(fn -> :ets.delete(table, buffer) end)
  end

  defp conflict_content do
    "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch"
  end
end
