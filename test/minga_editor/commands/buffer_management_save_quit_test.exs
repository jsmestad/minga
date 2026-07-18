defmodule MingaEditor.Commands.BufferManagementSaveQuitTest do
  @moduledoc false

  # Mutates Application env (:minga, :shutdown_fn); must not run concurrently with other tests.
  use Minga.Test.EditorCase, async: false, rendering: :disabled

  alias Minga.Buffer
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.State, as: EditorState

  @moduletag :tmp_dir

  setup do
    previous_shutdown_fn = Application.get_env(:minga, :shutdown_fn)
    test_pid = self()

    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, :shutdown_fn, fn status -> send(test_pid, {:shutdown, status}) end)

    on_exit(fn ->
      case previous_shutdown_fn do
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        nil -> Application.delete_env(:minga, :shutdown_fn)
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        shutdown_fn -> Application.put_env(:minga, :shutdown_fn, shutdown_fn)
      end
    end)

    :ok
  end

  test "failed :wq keeps the active tab open and preserves the save notice" do
    ctx = start_editor("")
    send_ex_sync(ctx, "new")
    active_before = active_buffer(ctx)
    labels_before = tab_labels(ctx)

    send_ex_sync(ctx, "wq")

    assert active_buffer(ctx) == active_before
    assert tab_labels(ctx) == labels_before
    assert notice_message(ctx) == "No file name — use :w <filename>"
    refute_received {:shutdown, 0}
  end

  test "successful :wq saves and closes the active tab", %{tmp_dir: root} do
    first_path = Path.join(root, "first.txt")
    second_path = Path.join(root, "second.txt")
    File.write!(first_path, "first")
    File.write!(second_path, "second")

    ctx = start_editor("first", file_path: first_path)
    :ok = MingaEditor.open_file(ctx.editor, second_path)
    second_buffer = active_buffer(ctx)
    :ok = Buffer.insert_text(second_buffer, " edited")

    send_ex_sync(ctx, "wq")

    assert File.read!(second_path) == " editedsecond"
    assert length(visible_file_tabs(ctx, active_workspace_id(ctx))) == 1
    refute "second.txt" in tab_labels(ctx)
    refute_received {:shutdown, 0}
  end

  test "failed :wqa does not shut down and stops before later buffers", %{tmp_dir: root} do
    later_path = Path.join(root, "later.txt")
    File.write!(later_path, "later")

    ctx = start_editor("")
    first_buffer = active_buffer(ctx)
    :ok = Buffer.insert_text(first_buffer, "first")
    :ok = MingaEditor.open_file(ctx.editor, later_path)
    later_buffer = active_buffer(ctx)
    :ok = Buffer.insert_text(later_buffer, " changed")

    send_ex_sync(ctx, "wqa")

    refute_received {:shutdown, 0}
    assert Buffer.dirty?(later_buffer)
    assert File.read!(later_path) == "later"
  end

  test "successful :wqa saves every current-workspace dirty buffer and invokes shutdown", %{
    tmp_dir: root
  } do
    first_path = Path.join(root, "first.txt")
    second_path = Path.join(root, "second.txt")
    File.write!(first_path, "first")
    File.write!(second_path, "second")

    ctx = start_editor("first", file_path: first_path)
    first_buffer = active_buffer(ctx)
    :ok = MingaEditor.open_file(ctx.editor, second_path)
    second_buffer = active_buffer(ctx)
    :ok = Buffer.insert_text(first_buffer, " edited")
    :ok = Buffer.insert_text(second_buffer, " edited")

    send_ex_sync(ctx, "wqa")

    assert File.read!(first_path) == " editedfirst"
    assert File.read!(second_path) == " editedsecond"
    refute Buffer.dirty?(first_buffer)
    refute Buffer.dirty?(second_buffer)
    assert_received {:shutdown, 0}
  end

  test "active buffer exit is a failed :wq" do
    ctx = start_editor("")
    state = editor_state(ctx)
    buffer = state.workspace.buffers.active
    monitor_ref = Process.monitor(buffer)
    :ok = GenServer.stop(buffer)
    assert_receive {:DOWN, ^monitor_ref, :process, ^buffer, _reason}

    result = BufferManagement.execute(state, {:execute_ex_command, {:save_quit, []}})

    assert %EditorState{} = result

    assert String.starts_with?(
             MingaEditor.Shell.Traditional.NoticeWorkflow.message(result),
             "Save failed:"
           )

    refute_received {:shutdown, 0}
  end

  test "buffer exit stops :wqa without shutdown" do
    ctx = start_editor("")
    state = editor_state(ctx)
    buffer = state.workspace.buffers.active
    monitor_ref = Process.monitor(buffer)
    :ok = GenServer.stop(buffer)
    assert_receive {:DOWN, ^monitor_ref, :process, ^buffer, _reason}

    result = BufferManagement.execute(state, {:execute_ex_command, {:save_quit_all, []}})

    assert %EditorState{} = result
    refute_received {:shutdown, 0}
  end
end
