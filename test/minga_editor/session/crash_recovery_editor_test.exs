defmodule MingaEditor.Session.CrashRecoveryEditorTest do
  @moduledoc "A file buffer that crashes with unsaved text is reopened in the same session with that text."

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.Session.Swap
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @timeout 15_000

  test "the crashed buffer is retired and the file comes back with its unsaved text", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "notes.txt")
    File.write!(path, "saved text")
    swap_dir = Path.join(dir, "swap")

    ctx = start_editor("scratch")
    registry = :sys.get_state(ctx.editor).extension_surfaces.events_registry
    :ok = Events.subscribe(:buffer_opened, registry)

    crashed =
      start_supervised!(
        {BufferProcess, file_path: path, swap_dir: swap_dir, events_registry: registry},
        id: make_ref()
      )

    :sys.replace_state(ctx.editor, &BufferRegistry.register_buffer(&1, crashed, path))
    :ok = BufferProcess.replace_content(crashed, "unsaved text")

    monitor = Process.monitor(crashed)
    send(crashed, :message_no_callback_handles)
    assert_receive {:DOWN, ^monitor, :process, ^crashed, _reason}, @timeout

    # The editor reads the swap off its own process, then opens a new buffer for the file.
    assert_receive {:minga_event, :buffer_opened,
                    %Events.BufferEvent{buffer: reopened, path: ^path}},
                   @timeout

    on_exit(fn -> stop_buffer(reopened) end)
    state = :sys.get_state(ctx.editor)

    assert reopened != crashed
    assert Buffer.content(reopened) == "unsaved text"
    assert Buffer.dirty?(reopened)
    assert state.workspace.buffers.active == reopened
    refute crashed in state.workspace.buffers.list
    assert NoticeWorkflow.message(state) =~ "notes.txt was reopened with its unsaved text"

    # The read does not consume the swap: the text is still unsaved, so it must survive a second failure.
    assert File.exists?(Swap.swap_path(path, swap_dir: swap_dir))
  end

  test "a buffer that crashes without unsaved text is retired and nothing is reopened", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "clean.txt")
    File.write!(path, "saved text")

    ctx = start_editor("scratch")
    registry = :sys.get_state(ctx.editor).extension_surfaces.events_registry
    :ok = Events.subscribe(:buffer_opened, registry)

    crashed =
      start_supervised!(
        {BufferProcess,
         file_path: path, swap_dir: Path.join(dir, "swap"), events_registry: registry},
        id: make_ref()
      )

    :sys.replace_state(ctx.editor, &BufferRegistry.register_buffer(&1, crashed, path))

    monitor = Process.monitor(crashed)
    send(crashed, :message_no_callback_handles)
    assert_receive {:DOWN, ^monitor, :process, ^crashed, _reason}, @timeout

    # The runtime delivers the editor's own `:DOWN` separately, so wait for the retirement itself.
    wait_until(ctx, fn state -> crashed not in state.workspace.buffers.list end)
    :sys.get_state(ctx.editor)
    refute_receive {:minga_event, :buffer_opened, %Events.BufferEvent{path: ^path}}, 0
    assert Buffer.pid_for_path(path) == :not_found
  end

  defp stop_buffer(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end
end
