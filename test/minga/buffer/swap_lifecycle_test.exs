defmodule Minga.Buffer.SwapLifecycleTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Session
  alias Minga.Session.ControllableSwapBackend
  alias Minga.Session.Swap
  alias Minga.Session.Swap.Recovery

  @moduletag :tmp_dir
  @publication_timeout 2_000

  test "newer admitted content cannot complete behind an older paused preparation", %{
    tmp_dir: tmp_dir
  } do
    {buffer, path} = start_swap_buffer(tmp_dir)

    :ok = BufferProcess.replace_content(buffer, "older dirty content")
    {older_worker, older_generation} = trigger_swap(buffer, path, "older dirty content")

    :ok = BufferProcess.replace_content(buffer, "newest dirty content")
    send(buffer, :write_swap)
    :sys.get_state(buffer)

    refute_receive {:swap_prepare, _worker, _generation, ^path, "newest dirty content"}, 0

    release_prepare(older_worker, older_generation)

    assert_receive {:swap_discarded, ^buffer, ^older_worker, ^older_generation, ^path,
                    "older dirty content", :ok}

    assert_receive {:swap_prepare, newest_worker, newest_generation, ^path,
                    "newest dirty content"}

    assert newest_generation > older_generation
    release_prepare(newest_worker, newest_generation)

    assert_receive {:swap_published, ^buffer, ^newest_worker, ^newest_generation, ^path,
                    "newest dirty content", :ok},
                   @publication_timeout

    refute_receive {:swap_published, ^buffer, ^older_worker, ^older_generation, ^path, _content,
                    _result},
                   0

    swap_path = Swap.swap_path(path, swap_options(tmp_dir))
    assert {:ok, ^path, "newest dirty content"} = Session.recover_swap_file(swap_path)
  end

  test "save revokes a paused preparation before deleting the published swap", %{tmp_dir: tmp_dir} do
    {buffer, path} = start_swap_buffer(tmp_dir)

    :ok = BufferProcess.replace_content(buffer, "unsaved")
    {worker, generation} = trigger_swap(buffer, path, "unsaved")
    worker_monitor = Process.monitor(worker)

    assert :ok = BufferProcess.save(buffer)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    assert_receive {:swap_deleted, ^buffer, ^path, :ok}

    release_prepare(worker, generation)
    refute_receive {:swap_published, ^buffer, ^worker, ^generation, ^path, _content, _result}, 0
    refute File.exists?(Swap.swap_path(path, swap_options(tmp_dir)))
    assert File.read!(path) == "unsaved"
  end

  test "clean close owns paused writer termination and prevents later publication", %{
    tmp_dir: tmp_dir
  } do
    {buffer, path} = start_swap_buffer(tmp_dir)

    :ok = BufferProcess.replace_content(buffer, "closing dirty content")
    {worker, generation} = trigger_swap(buffer, path, "closing dirty content")
    worker_monitor = Process.monitor(worker)
    buffer_monitor = Process.monitor(buffer)

    assert :ok = GenServer.stop(buffer, :normal)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    assert_receive {:DOWN, ^buffer_monitor, :process, ^buffer, :normal}
    assert_receive {:swap_deleted, ^buffer, ^path, :ok}

    release_prepare(worker, generation)
    refute_receive {:swap_published, ^buffer, ^worker, ^generation, ^path, _content, _result}, 0
    refute File.exists?(Swap.swap_path(path, swap_options(tmp_dir)))
  end

  test "abrupt owner exit terminates a paused preparation before it can publish", %{
    tmp_dir: tmp_dir
  } do
    {buffer, path} =
      start_swap_buffer(tmp_dir, swap_backend_options: [prepare_barrier: :after_temp])

    :ok = BufferProcess.replace_content(buffer, "crashing dirty content")
    {io_worker, generation} = trigger_swap(buffer, path, "crashing dirty content")
    assert_received {:swap_temp_created, ^io_worker, ^generation, ^path, temporary_path}
    assert File.exists?(temporary_path)
    io_monitor = Process.monitor(io_worker)
    buffer_monitor = Process.monitor(buffer)

    Process.exit(buffer, :kill)

    assert_receive {:DOWN, ^buffer_monitor, :process, ^buffer, :killed}
    assert_receive {:DOWN, ^io_monitor, :process, ^io_worker, :killed}

    release_prepare(io_worker, generation)

    refute_receive {:swap_published, ^buffer, ^io_worker, ^generation, ^path, _content, _result},
                   0

    refute File.exists?(Swap.swap_path(path, swap_options(tmp_dir)))
    assert File.exists?(temporary_path)
    scan_options = Keyword.put(swap_options(tmp_dir), :pid_alive?, fn _os_pid -> false end)
    assert Recovery.scan(scan_options) == []
    refute File.exists?(temporary_path)
  end

  test "worker death keeps the buffer alive and persists the latest pending version", %{
    tmp_dir: tmp_dir
  } do
    {buffer, path} = start_swap_buffer(tmp_dir)

    :ok = BufferProcess.replace_content(buffer, "first dirty content")
    {failed_worker, failed_generation} = trigger_swap(buffer, path, "first dirty content")

    :ok = BufferProcess.replace_content(buffer, "recovered dirty content")
    send(buffer, :write_swap)
    :sys.get_state(buffer)

    failed_monitor = Process.monitor(failed_worker)
    Process.exit(failed_worker, :kill)
    assert_receive {:DOWN, ^failed_monitor, :process, ^failed_worker, :killed}

    assert_receive {:swap_prepare, recovery_worker, recovery_generation, ^path,
                    "recovered dirty content"}

    assert recovery_generation > failed_generation
    release_prepare(recovery_worker, recovery_generation)

    assert_receive {:swap_published, ^buffer, ^recovery_worker, ^recovery_generation, ^path,
                    "recovered dirty content", :ok},
                   @publication_timeout

    assert BufferProcess.content(buffer) == "recovered dirty content"
    swap_path = Swap.swap_path(path, swap_options(tmp_dir))
    assert {:ok, ^path, "recovered dirty content"} = Session.recover_swap_file(swap_path)
  end

  test "undo to another dirty version schedules and publishes that restored content", %{
    tmp_dir: tmp_dir
  } do
    timer_start = controlled_timer_start(self())
    {buffer, path} = start_swap_buffer(tmp_dir, swap_timer_start: timer_start)

    :ok = BufferProcess.replace_content(buffer, "published dirty content")
    assert_receive {:swap_scheduled, ^buffer, {:write_swap, first_token}}
    drive_swap_timer(buffer, first_token)

    assert_receive {:swap_prepare, first_worker, first_generation, ^path,
                    "published dirty content"}

    release_prepare(first_worker, first_generation)

    assert_receive {:swap_published, ^buffer, ^first_worker, ^first_generation, ^path,
                    "published dirty content", :ok},
                   @publication_timeout

    :ok = BufferProcess.replace_content(buffer, "middle dirty content")
    assert_receive {:swap_scheduled, ^buffer, {:write_swap, middle_token}}
    :ok = BufferProcess.replace_content(buffer, "latest dirty content")
    assert_receive {:swap_scheduled, ^buffer, {:write_swap, latest_token}}
    :ok = BufferProcess.undo(buffer)
    assert_receive {:swap_scheduled, ^buffer, {:write_swap, undo_token}}

    drive_swap_timer(buffer, middle_token)
    drive_swap_timer(buffer, latest_token)
    refute_receive {:swap_prepare, _worker, _generation, ^path, _content}, 0

    drive_swap_timer(buffer, undo_token)

    assert_receive {:swap_prepare, undo_worker, undo_generation, ^path, "middle dirty content"}
    release_prepare(undo_worker, undo_generation)

    assert_receive {:swap_published, ^buffer, ^undo_worker, ^undo_generation, ^path,
                    "middle dirty content", :ok},
                   @publication_timeout

    swap_path = Swap.swap_path(path, swap_options(tmp_dir))
    assert {:ok, ^path, "middle dirty content"} = Session.recover_swap_file(swap_path)
  end

  test "save removes a temporary file created before preparation is cancelled", %{
    tmp_dir: tmp_dir
  } do
    {buffer, path} =
      start_swap_buffer(tmp_dir, swap_backend_options: [prepare_barrier: :after_temp])

    :ok = BufferProcess.replace_content(buffer, "unsaved after temp")
    {worker, generation} = trigger_swap(buffer, path, "unsaved after temp")
    assert_received {:swap_temp_created, ^worker, ^generation, ^path, temporary_path}
    assert File.exists?(temporary_path)
    worker_monitor = Process.monitor(worker)

    assert :ok = BufferProcess.save(buffer)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    assert_receive {:swap_deleted, ^buffer, ^path, :ok}
    refute File.exists?(temporary_path)
  end

  test "publication failure removes stale recovery data and a later version can publish", %{
    tmp_dir: tmp_dir
  } do
    {buffer, path} = start_swap_buffer(tmp_dir)
    swap_path = Swap.swap_path(path, swap_options(tmp_dir))

    :ok = BufferProcess.replace_content(buffer, "previously published")
    {first_worker, first_generation} = trigger_swap(buffer, path, "previously published")
    release_prepare(first_worker, first_generation)

    assert_receive {:swap_published, ^buffer, ^first_worker, ^first_generation, ^path,
                    "previously published", :ok},
                   @publication_timeout

    assert File.exists?(swap_path)

    :ok = BufferProcess.replace_content(buffer, "failed publication")
    {failed_worker, failed_generation} = trigger_swap(buffer, path, "failed publication")
    release_prepare(failed_worker, failed_generation, publish: {:error, :injected_publish})

    assert_receive {:swap_published, ^buffer, ^failed_worker, ^failed_generation, ^path,
                    "failed publication", {:error, :injected_publish}},
                   @publication_timeout

    assert_receive {:swap_deleted, ^buffer, ^path, :ok}
    refute File.exists?(swap_path)

    :ok = BufferProcess.replace_content(buffer, "later recovery content")
    {later_worker, later_generation} = trigger_swap(buffer, path, "later recovery content")
    release_prepare(later_worker, later_generation)

    assert_receive {:swap_published, ^buffer, ^later_worker, ^later_generation, ^path,
                    "later recovery content", :ok},
                   @publication_timeout

    assert {:ok, ^path, "later recovery content"} = Session.recover_swap_file(swap_path)
  end

  test "discard failure remains explicit without stopping the buffer", %{
    tmp_dir: tmp_dir
  } do
    {buffer, path} = start_swap_buffer(tmp_dir)

    :ok = BufferProcess.replace_content(buffer, "obsolete content")
    {obsolete_worker, obsolete_generation} = trigger_swap(buffer, path, "obsolete content")
    :ok = BufferProcess.replace_content(buffer, "current content")
    send(buffer, :write_swap)
    :sys.get_state(buffer)

    release_prepare(obsolete_worker, obsolete_generation, discard: {:error, :injected_discard})

    assert_receive {:swap_discarded, ^buffer, ^obsolete_worker, ^obsolete_generation, ^path,
                    "obsolete content", {:error, :injected_discard}}

    assert_receive {:swap_prepare, current_worker, current_generation, ^path, "current content"}
    release_prepare(current_worker, current_generation)

    assert_receive {:swap_published, ^buffer, ^current_worker, ^current_generation, ^path,
                    "current content", :ok},
                   @publication_timeout

    assert BufferProcess.content(buffer) == "current content"
  end

  test "delete failure remains explicit without stopping the buffer", %{tmp_dir: tmp_dir} do
    {buffer, path} =
      start_swap_buffer(tmp_dir,
        swap_backend_options: [delete: {:error, :injected_delete}]
      )

    :ok = BufferProcess.replace_content(buffer, "content before save")
    {worker, generation} = trigger_swap(buffer, path, "content before save")
    release_prepare(worker, generation)

    assert_receive {:swap_published, ^buffer, ^worker, ^generation, ^path, "content before save",
                    :ok},
                   @publication_timeout

    assert :ok = BufferProcess.save(buffer)
    assert_receive {:swap_deleted, ^buffer, ^path, {:error, :injected_delete}}
    assert Process.alive?(buffer)
    assert BufferProcess.content(buffer) == "content before save"
  end

  defp start_swap_buffer(tmp_dir, extra_opts \\ []) do
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "buffer.txt")
    File.write!(path, "saved content")

    backend_options =
      [controller: self(), os_pid: 99_999]
      |> Keyword.merge(Keyword.get(extra_opts, :swap_backend_options, []))

    buffer_opts =
      [
        file_path: path,
        swap_dir: tmp_dir,
        swap_backend: ControllableSwapBackend,
        swap_backend_options: backend_options
      ]
      |> Keyword.merge(Keyword.delete(extra_opts, :swap_backend_options))

    buffer =
      start_supervised!({BufferProcess, buffer_opts}, id: make_ref())

    {buffer, path}
  end

  defp trigger_swap(buffer, path, content) do
    send(buffer, :write_swap)
    :sys.get_state(buffer)
    assert_receive {:swap_prepare, worker, generation, ^path, ^content}
    {worker, generation}
  end

  defp release_prepare(worker, generation, controls \\ []) do
    result = if controls == [], do: :ok, else: {:ok, controls}
    send(worker, {:swap_prepare_result, generation, result})
    :ok
  end

  defp controlled_timer_start(controller) do
    fn owner, message, _delay ->
      send(controller, {:swap_scheduled, owner, message})
      make_ref()
    end
  end

  defp drive_swap_timer(buffer, token) do
    send(buffer, {:write_swap, token})
    :sys.get_state(buffer)
    :ok
  end

  defp swap_options(tmp_dir), do: [swap_dir: tmp_dir, os_pid: 99_999]
end
