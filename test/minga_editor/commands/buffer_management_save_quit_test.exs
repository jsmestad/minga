defmodule MingaEditor.Commands.BufferManagementSaveQuitTest do
  @moduledoc false

  # Mutates Application env (:minga, :shutdown_fn); must not run concurrently with other tests.
  use Minga.Test.EditorCase, async: false, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Frontend.WaitRequestCompletion
  alias Minga.Frontend.WaitRequests
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar

  @moduletag :tmp_dir

  setup_all do
    case Process.whereis(WaitRequests) do
      nil ->
        {:ok, tracker} = WaitRequests.start_link()
        on_exit(fn -> GenServer.stop(tracker, :normal) end)

      _pid ->
        :ok
    end

    :ok
  end

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

  test "LSP format timeout lets :wq save and close only through the continuation", %{
    tmp_dir: root
  } do
    path = Path.join(root, "lsp-timeout-wq.txt")
    File.write!(path, "file")
    ctx = start_editor("file", file_path: path)
    buffer = active_buffer(ctx)
    client = fake_lsp_client(self())
    Minga.LSP.SyncServer.put_clients(buffer, [client])
    on_exit(fn -> Minga.LSP.SyncServer.remove_buffer(buffer) end)

    assert {:ok, _previous} = BufferProcess.set_option(buffer, :format_on_save, true)
    :ok = Buffer.insert_text(buffer, " edited")

    send_ex_sync(ctx, "wq")

    assert_receive {:format_request, ref, _caller}
    assert File.read!(path) == "file"
    refute_received {:shutdown, 0}

    send(ctx.editor, {:lsp_format_timeout, ref})

    assert_receive {:shutdown, 0}
    assert File.read!(path) == " editedfile"
  end

  test "async :wq restores the completion-time active file tab after the user switches tabs", %{
    tmp_dir: root
  } do
    first_path = Path.join(root, "first.txt")
    c_path = Path.join(root, "c.txt")
    b_path = Path.join(root, "b.txt")
    File.write!(first_path, "first")
    File.write!(c_path, "c")
    File.write!(b_path, "b")

    ctx = start_editor("first", file_path: first_path)
    first_buffer = active_buffer(ctx)
    client = fake_lsp_client(self())
    Minga.LSP.SyncServer.put_clients(first_buffer, [client])
    on_exit(fn -> Minga.LSP.SyncServer.remove_buffer(first_buffer) end)

    assert {:ok, _previous} = BufferProcess.set_option(first_buffer, :format_on_save, true)
    :ok = Buffer.insert_text(first_buffer, " edited")
    :ok = MingaEditor.open_file(ctx.editor, c_path)
    c_buffer = active_buffer(ctx)
    :ok = MingaEditor.open_file(ctx.editor, b_path)
    b_buffer = active_buffer(ctx)
    send_keys_sync(ctx, "gT")
    assert active_buffer(ctx) == c_buffer
    send_keys_sync(ctx, "gT")
    assert active_buffer(ctx) == first_buffer

    send_ex_sync(ctx, "wq")

    assert_receive {:format_request, ref, _caller}
    assert File.read!(first_path) == "first"
    send_keys_sync(ctx, "gt")
    send_keys_sync(ctx, "gt")
    assert active_buffer(ctx) == b_buffer

    send(ctx.editor, {:lsp_format_timeout, ref})
    :sys.get_state(ctx.editor)

    assert File.read!(first_path) == " editedfirst"
    refute "first.txt" in tab_labels(ctx)
    assert "c.txt" in tab_labels(ctx)
    assert "b.txt" in tab_labels(ctx)
    assert active_buffer(ctx) == b_buffer
    refute_received {:shutdown, 0}
  end

  test "async :wq restores a completion-time active agent tab without shutdown", %{
    tmp_dir: root
  } do
    first_path = Path.join(root, "first.txt")
    c_path = Path.join(root, "c.txt")
    File.write!(first_path, "first")
    File.write!(c_path, "c")

    ctx = start_editor("first", file_path: first_path)
    first_buffer = active_buffer(ctx)
    client = fake_lsp_client(self())
    Minga.LSP.SyncServer.put_clients(first_buffer, [client])
    on_exit(fn -> Minga.LSP.SyncServer.remove_buffer(first_buffer) end)

    assert {:ok, _previous} = BufferProcess.set_option(first_buffer, :format_on_save, true)
    :ok = Buffer.insert_text(first_buffer, " edited")
    :ok = MingaEditor.open_file(ctx.editor, c_path)
    c_buffer = active_buffer(ctx)
    state = put_inactive_agent_tab(ctx, "Agent B")
    agent_tab_id = state.shell_runtime.state.tab_bar.active_id
    send_keys_sync(ctx, "gT")
    assert active_buffer(ctx) == c_buffer
    send_keys_sync(ctx, "gT")
    assert active_buffer(ctx) == first_buffer

    send_ex_sync(ctx, "wq")

    assert_receive {:format_request, ref, _caller}
    :sys.replace_state(ctx.editor, &MingaEditor.TabWorkflow.switch(&1, agent_tab_id))
    assert TabBar.active(editor_state(ctx).shell_runtime.state.tab_bar).kind == :agent
    send(ctx.editor, {:lsp_format_timeout, ref})
    :sys.get_state(ctx.editor)

    tb = editor_state(ctx).shell_runtime.state.tab_bar
    assert File.read!(first_path) == " editedfirst"
    refute "first.txt" in tab_labels(ctx)
    assert "c.txt" in tab_labels(ctx)
    assert TabBar.active(tb).kind == :agent
    assert tb.active_id == agent_tab_id
    refute_received {:shutdown, 0}
  end

  test "async :wq with the last file tab restores a completion-time active agent tab", %{
    tmp_dir: root
  } do
    first_path = Path.join(root, "first.txt")
    File.write!(first_path, "first")

    ctx = start_editor("first", file_path: first_path)
    first_buffer = active_buffer(ctx)
    client = fake_lsp_client(self())
    Minga.LSP.SyncServer.put_clients(first_buffer, [client])
    on_exit(fn -> Minga.LSP.SyncServer.remove_buffer(first_buffer) end)

    assert {:ok, _previous} = BufferProcess.set_option(first_buffer, :format_on_save, true)
    :ok = Buffer.insert_text(first_buffer, " edited")
    first_tab_id = editor_state(ctx).shell_runtime.state.tab_bar.active_id
    state = put_inactive_agent_tab(ctx, "Agent B")
    agent_tab_id = state.shell_runtime.state.tab_bar.active_id
    :sys.replace_state(ctx.editor, &MingaEditor.TabWorkflow.switch(&1, first_tab_id))
    assert active_buffer(ctx) == first_buffer

    send_ex_sync(ctx, "wq")

    assert_receive {:format_request, ref, _caller}
    :sys.replace_state(ctx.editor, &MingaEditor.TabWorkflow.switch(&1, agent_tab_id))
    send(ctx.editor, {:lsp_format_timeout, ref})
    :sys.get_state(ctx.editor)

    tb = editor_state(ctx).shell_runtime.state.tab_bar
    assert File.read!(first_path) == " editedfirst"
    refute "first.txt" in tab_labels(ctx)
    assert TabBar.active(tb).kind == :agent
    assert tb.active_id == agent_tab_id
    refute_received {:shutdown, 0}
  end

  test "async :wq falls back when the completion-time preferred tab disappeared", %{
    tmp_dir: root
  } do
    first_path = Path.join(root, "first.txt")
    c_path = Path.join(root, "c.txt")
    b_path = Path.join(root, "b.txt")
    File.write!(first_path, "first")
    File.write!(c_path, "c")
    File.write!(b_path, "b")

    ctx = start_editor("first", file_path: first_path)
    first_buffer = active_buffer(ctx)
    client = fake_lsp_client(self())
    Minga.LSP.SyncServer.put_clients(first_buffer, [client])
    on_exit(fn -> Minga.LSP.SyncServer.remove_buffer(first_buffer) end)

    assert {:ok, _previous} = BufferProcess.set_option(first_buffer, :format_on_save, true)
    :ok = Buffer.insert_text(first_buffer, " edited")
    :ok = MingaEditor.open_file(ctx.editor, c_path)
    c_buffer = active_buffer(ctx)
    c_tab_id = editor_state(ctx).shell_runtime.state.tab_bar.active_id
    :ok = MingaEditor.open_file(ctx.editor, b_path)
    b_tab_id = editor_state(ctx).shell_runtime.state.tab_bar.active_id
    send_keys_sync(ctx, "gT")
    send_keys_sync(ctx, "gT")
    assert active_buffer(ctx) == first_buffer

    send_ex_sync(ctx, "wq")

    assert_receive {:format_request, ref, _caller}

    :sys.replace_state(ctx.editor, fn state ->
      {:ok, tb} = TabBar.remove(state.shell_runtime.state.tab_bar, b_tab_id)
      state |> install_tab_bar(tb) |> MingaEditor.TabWorkflow.switch(c_tab_id)
    end)

    assert active_buffer(ctx) == c_buffer

    send(ctx.editor, {:lsp_format_timeout, ref})
    :sys.get_state(ctx.editor)

    assert File.read!(first_path) == " editedfirst"
    refute "first.txt" in tab_labels(ctx)
    assert "c.txt" in tab_labels(ctx)
    refute "b.txt" in tab_labels(ctx)
    assert active_buffer(ctx) == c_buffer
    refute_received {:shutdown, 0}
  end

  test "async :wq completion does not close the current tab when the origin tab disappeared", %{
    tmp_dir: root
  } do
    first_path = Path.join(root, "first.txt")
    second_path = Path.join(root, "second.txt")
    File.write!(first_path, "first")
    File.write!(second_path, "second")

    ctx = start_editor("first", file_path: first_path)
    first_buffer = active_buffer(ctx)
    client = fake_lsp_client(self())
    Minga.LSP.SyncServer.put_clients(first_buffer, [client])
    on_exit(fn -> Minga.LSP.SyncServer.remove_buffer(first_buffer) end)

    assert {:ok, _previous} = BufferProcess.set_option(first_buffer, :format_on_save, true)
    :ok = Buffer.insert_text(first_buffer, " edited")
    origin_tab_id = :sys.get_state(ctx.editor).shell_runtime.state.tab_bar.active_id
    :ok = MingaEditor.open_file(ctx.editor, second_path)
    second_buffer = active_buffer(ctx)
    send_keys_sync(ctx, "gT")

    send_ex_sync(ctx, "wq")

    assert_receive {:format_request, ref, _caller}
    send_keys_sync(ctx, "gt")
    assert active_buffer(ctx) == second_buffer

    :sys.replace_state(ctx.editor, fn state ->
      {:ok, tb} = TabBar.remove(state.shell_runtime.state.tab_bar, origin_tab_id)
      install_tab_bar(state, tb)
    end)

    send(ctx.editor, {:lsp_format_timeout, ref})
    :sys.get_state(ctx.editor)

    assert File.read!(first_path) == " editedfirst"
    refute "first.txt" in tab_labels(ctx)
    assert "second.txt" in tab_labels(ctx)
    assert active_buffer(ctx) == second_buffer
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

  test "successful :wqa saves dirty inactive-tab-only buffer and invokes shutdown", %{
    tmp_dir: root
  } do
    active_path = Path.join(root, "active.txt")
    inactive_path = Path.join(root, "inactive.txt")
    File.write!(active_path, "active")
    File.write!(inactive_path, "inactive")

    ctx = start_editor("active", file_path: active_path)
    {:ok, inactive_buffer} = BufferProcess.start_link(file_path: inactive_path)
    :ok = Buffer.insert_text(inactive_buffer, " edited")
    put_inactive_file_tab(ctx, inactive_buffer, "inactive.txt")

    send_ex_sync(ctx, "wqa")

    assert File.read!(inactive_path) == " editedinactive"
    refute Buffer.dirty?(inactive_buffer)
    assert_received {:shutdown, 0}
  end

  test ":quit_all asks for confirmation when only inactive tab inventory is dirty", %{
    tmp_dir: root
  } do
    active_path = Path.join(root, "active.txt")
    inactive_path = Path.join(root, "inactive.txt")
    File.write!(active_path, "active")
    File.write!(inactive_path, "inactive")

    ctx = start_editor("active", file_path: active_path)
    {:ok, inactive_buffer} = BufferProcess.start_link(file_path: inactive_path)
    :ok = Buffer.insert_text(inactive_buffer, " edited")
    state = put_inactive_file_tab(ctx, inactive_buffer, "inactive.txt")

    result = BufferManagement.execute(state, :quit_all)

    assert state_notice_message(result) == "Modified buffers exist. Really quit? (y/n)"
    refute_received {:shutdown, 0}
  end

  test "confirmed :quit_all cancels wait requests for dirty inactive tab inventory", %{
    tmp_dir: root
  } do
    active_path = Path.join(root, "active.txt")
    inactive_path = Path.join(root, "inactive.txt")
    File.write!(active_path, "active")
    File.write!(inactive_path, "inactive")

    ctx = start_editor("active", file_path: active_path)
    {:ok, inactive_buffer} = BufferProcess.start_link(file_path: inactive_path)
    :ok = Buffer.insert_text(inactive_buffer, " edited")
    state = put_inactive_file_tab(ctx, inactive_buffer, "inactive.txt")
    request_id = "save-quit-test-#{System.unique_integer([:positive])}"
    :ok = WaitRequests.register(inactive_buffer, inactive_path, request_id, self())

    state =
      state
      |> BufferManagement.execute(:quit_all)
      |> BufferManagement.execute(:confirm_quit_yes)

    assert %EditorState{} = state

    assert_receive %WaitRequestCompletion{
      request_id: ^request_id,
      outcome: {:cancelled, "discarded after quit confirmation"}
    }

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

  defp put_inactive_file_tab(ctx, buffer, label) do
    :sys.replace_state(ctx.editor, fn state ->
      tb = state.shell_runtime.state.tab_bar
      {tb, tab} = TabBar.insert(tb, :file, label)

      workspace =
        MingaEditor.Session.State.set_buffers(
          state.workspace,
          %Buffers{active: buffer, list: [buffer], active_index: 0}
        )

      tb = TabBar.update_context(tb, tab.id, TabContext.snapshot(workspace))
      install_tab_bar(state, tb)
    end)
  end

  defp put_inactive_agent_tab(ctx, label) do
    :sys.replace_state(ctx.editor, fn state ->
      tb = state.shell_runtime.state.tab_bar
      {tb, tab} = TabBar.insert(tb, :agent, label)

      context =
        TabContext.new_agent(
          state.frontend.terminal_viewport,
          state.workspace.file_tree.project_root
        )

      tb = tb |> TabBar.update_context(tab.id, context) |> TabBar.switch_to(tab.id)
      install_tab_bar(state, tb)
    end)
  end

  defp install_tab_bar(state, %TabBar{} = tb) do
    shell_state =
      TraditionalState.install_tab_bar(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        tb
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  defp fake_lsp_client(parent) do
    start_supervised!(
      {Task, fn -> fake_lsp_client_loop(parent) end},
      id: {:fake_lsp_client, make_ref()}
    )
  end

  defp fake_lsp_client_loop(parent) do
    receive do
      {:"$gen_call", from, :capabilities} ->
        GenServer.reply(from, %{"documentFormattingProvider" => true})
        fake_lsp_client_loop(parent)

      {:"$gen_call", from, :encoding} ->
        GenServer.reply(from, :utf16)
        fake_lsp_client_loop(parent)

      {:"$gen_cast", {:cancel_request, ref}} ->
        send(parent, {:cancel_request, ref})
        fake_lsp_client_loop(parent)

      {:"$gen_cast", {:async_request, "textDocument/formatting", _params, caller, ref}} ->
        send(parent, {:format_request, ref, caller})
        fake_lsp_client_loop(parent)
    end
  end

  defp state_notice_message(state) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.message(state)
  end
end
