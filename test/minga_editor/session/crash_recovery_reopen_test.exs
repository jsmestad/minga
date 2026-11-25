defmodule MingaEditor.Session.CrashRecoveryReopenTest do
  # Uses the application-wide buffer supervisor and buffer registry while reopening real file buffers.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.Parser.Manager
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Session.CrashRecovery
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Startup

  @moduletag :tmp_dir

  test "a crashed buffer's file is reopened dirty with its unsaved text", %{tmp_dir: dir} do
    path = Path.join(dir, "crashed.txt")
    File.write!(path, "saved text\n")
    state = initial_state(dir)

    {recovered, _outcome} = CrashRecovery.apply(state, read(path, "unsaved text\n"))
    buffer = recovered.workspace.buffers.active
    on_exit(fn -> stop_buffer(buffer) end)

    assert Minga.Buffer.file_path(buffer) == path
    assert Minga.Buffer.content(buffer) == "unsaved text\n"
    assert Minga.Buffer.dirty?(buffer)
    assert NoticeWorkflow.message(recovered) =~ "crashed.txt was reopened with its unsaved text"
  end

  test "a file that was deleted since the crash comes back as a buffer for its path", %{
    tmp_dir: dir
  } do
    missing = Path.join(dir, "deleted-since.txt")
    state = initial_state(dir)

    {recovered, _outcome} = CrashRecovery.apply(state, read(missing, "unsaved text"))
    buffer = recovered.workspace.buffers.active
    on_exit(fn -> stop_buffer(buffer) end)

    assert Minga.Buffer.file_path(buffer) == missing
    assert Minga.Buffer.content(buffer) == "unsaved text"
    assert Minga.Buffer.dirty?(buffer)
  end

  test "a file that cannot be reopened leaves the editor unchanged", %{tmp_dir: dir} do
    # A regular file stands where the directory was, so no buffer can open the path.
    blocker = Path.join(dir, "now-a-file")
    File.write!(blocker, "")
    unopenable = Path.join(blocker, "notes.txt")
    state = initial_state(dir)

    log =
      capture_log(fn ->
        assert {^state, _outcome} = CrashRecovery.apply(state, read(unopenable, "unsaved text"))
      end)

    assert log =~ "Could not reopen #{unopenable}"
    assert log =~ "It stays in #{unopenable}.swap"
  end

  test "a background buffer comes back in the background", %{tmp_dir: dir} do
    path = Path.join(dir, "background.txt")
    File.write!(path, "saved text\n")
    state = initial_state(dir)
    active_before = state.workspace.buffers.active

    {recovered, _outcome} =
      CrashRecovery.apply(state, read(path, "unsaved text\n", activate?: false))

    {:ok, buffer} = Minga.Buffer.pid_for_path(path)
    on_exit(fn -> stop_buffer(buffer) end)

    assert buffer in recovered.workspace.buffers.list
    assert recovered.workspace.buffers.active == active_before
    assert Minga.Buffer.content(buffer) == "unsaved text\n"
  end

  test "a buffer that is open again for the file keeps its newer text", %{tmp_dir: dir} do
    path = Path.join(dir, "reopened.txt")
    File.write!(path, "saved text\n")
    state = initial_state(dir)

    {:ok, reopened} = Minga.Buffer.ensure_for_path(path)
    on_exit(fn -> stop_buffer(reopened) end)
    :ok = Minga.Buffer.replace_content(reopened, "newer text\n", :recovery)

    log =
      capture_log(fn ->
        assert {^state, _outcome} = CrashRecovery.apply(state, read(path, "crash text\n"))
      end)

    assert Minga.Buffer.content(reopened) == "newer text\n"
    assert log =~ "#{path} is open again"
    assert log =~ path <> ".swap"
  end

  test "the reopened buffer is marked, so a crash of it is not recovered again", %{tmp_dir: dir} do
    path = Path.join(dir, "marked.txt")
    File.write!(path, "saved text\n")
    state = initial_state(dir)

    {recovered, _outcome} = CrashRecovery.apply(state, read(path, "unsaved text\n"))
    buffer = recovered.workspace.buffers.active
    on_exit(fn -> stop_buffer(buffer) end)

    crash = %Minga.Events.BufferCrashedEvent{
      buffer: buffer,
      path: path,
      swap_path: path <> ".swap"
    }

    announced = MingaEditor.State.record_buffer_crash(recovered, crash)

    assert {{:repeated, ^crash}, _state} = MingaEditor.State.take_buffer_crash(announced, buffer)
  end

  # The outcome of a finished swap read for `path`.
  defp read(path, content, opts \\ []) do
    effect = %CrashRecovery{
      path: path,
      swap_path: path <> ".swap",
      activate?: Keyword.get(opts, :activate?, true)
    }

    request = Request.new(effect, {:crash_recovery, path}, Policy.fifo(1))
    Outcome.completed(request, {path, content})
  end

  defp stop_buffer(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  defp initial_state(dir) do
    manager_name = Module.concat(__MODULE__, "Parser#{System.unique_integer([:positive])}")

    manager =
      start_supervised!({Manager, name: manager_name, parser_path: "/missing/minga-parser"})

    sidebar = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({MingaEditor.Extension.Sidebar, name: sidebar, notify: false})

    Startup.build_initial_state(
      backend: :headless,
      port_manager: nil,
      parser_manager: manager,
      sidebar_registry: sidebar,
      session_dir: dir,
      project_root: dir
    )
  end
end
