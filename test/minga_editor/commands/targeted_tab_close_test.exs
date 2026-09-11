defmodule MingaEditor.Commands.TargetedTabCloseTest do
  @moduledoc "Production-path contracts for ID-scoped native tab close requests."

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Minga.Buffer
  alias Minga.Config.Options
  alias Minga.Frontend.WaitRequestCompletion
  alias Minga.Frontend.WaitRequests
  alias MingaEditor.Commands
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Startup
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.Launchpad
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.TabWorkflow

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

  setup %{tmp_dir: tmp} do
    %{options: start_supervised!({Options, name: nil}), tmp: tmp}
  end

  test "an unknown ID is an exact no-op before any tab or wait effect", ctx do
    {state, [{first, _first_id}, {second, _second_id}]} =
      state_with_files(ctx, ["first", "second"])

    first_content = Buffer.content(first)
    second_cursor = Buffer.cursor(second)
    first_request = register_wait(first, ctx.tmp, "first")
    second_request = register_wait(second, ctx.tmp, "second")

    assert GuiActionHandler.dispatch(state, {:close_tab, 999_999}) == state
    assert Process.alive?(first) and Process.alive?(second)
    assert Buffer.content(first) == first_content
    assert Buffer.cursor(second) == second_cursor
    assert wait_pending?(first, first_request)
    assert wait_pending?(second, second_request)
    refute_received %WaitRequestCompletion{}
  end

  test "a target removed before delivery and a duplicate successful delivery are no-ops", ctx do
    {state, [{first, first_id}, {second, second_id}, {third, third_id}]} =
      state_with_files(ctx, ["first", "second", "third"])

    {:ok, without_first} = TabBar.remove(tab_bar(state), first_id)
    removed_before_delivery = install_tab_bar(state, without_first)
    active_request = register_wait(third, ctx.tmp, "third")

    assert GuiActionHandler.dispatch(removed_before_delivery, {:close_tab, first_id}) ==
             removed_before_delivery

    assert wait_pending?(third, active_request)
    refute_received %WaitRequestCompletion{request_id: ^active_request}

    closed = GuiActionHandler.dispatch(removed_before_delivery, {:close_tab, second_id})
    assert TabBar.get(tab_bar(closed), second_id) == nil
    assert tab_bar(closed).active_id == third_id
    assert Process.alive?(first) and Process.alive?(second) and Process.alive?(third)
    assert GuiActionHandler.dispatch(closed, {:close_tab, second_id}) == closed
    assert wait_pending?(third, active_request)
    refute_received %WaitRequestCompletion{request_id: ^active_request}
  end

  test "closing an inactive clean file tab retains its process and restores active context",
       ctx do
    {state, [{target, target_id}, {active, active_id}]} =
      state_with_files(ctx, ["target", "active"])

    request_id = register_wait(target, ctx.tmp, "target")
    target_monitor = Process.monitor(target)

    closed = GuiActionHandler.dispatch(state, {:close_tab, target_id})

    assert_receive %WaitRequestCompletion{request_id: ^request_id, outcome: :accepted}
    assert TabBar.get(tab_bar(closed), target_id) == nil
    assert tab_bar(closed).active_id == active_id
    assert closed.workspace.buffers.active == active
    assert Buffer.content(target) == "target"
    refute_received {:DOWN, ^target_monitor, :process, ^target, _reason}
  end

  test "closing an inactive dirty file tab retains content and its pending wait request", ctx do
    {state, [{target, target_id}, {active, active_id}]} =
      state_with_files(ctx, ["target", "active"])

    :ok = Buffer.insert_text(target, "changed ")
    content = Buffer.content(target)
    request_id = register_wait(target, ctx.tmp, "target")
    target_monitor = Process.monitor(target)

    closed = GuiActionHandler.dispatch(state, {:close_tab, target_id})

    assert TabBar.get(tab_bar(closed), target_id) == nil
    assert tab_bar(closed).active_id == active_id
    assert closed.workspace.buffers.active == active
    assert Process.alive?(target) and Buffer.content(target) == content and Buffer.dirty?(target)
    assert wait_pending?(target, request_id)
    refute_received %WaitRequestCompletion{request_id: ^request_id}
    refute_received {:DOWN, ^target_monitor, :process, ^target, _reason}
  end

  test "closing an inactive file tab preserves active tab operations", ctx do
    {state, [{_target, target_id}, {active, active_id}]} =
      state_with_files(ctx, ["target", "active"])

    {state, operations} = track_tab_operations(state, active_id)

    closed = GuiActionHandler.dispatch(state, {:close_tab, target_id})

    assert tab_bar(closed).active_id == active_id
    assert closed.workspace.buffers.active == active
    assert_tab_operations_preserved(closed, active_id, operations)
  end

  test "closing the last dirty file tab refuses visibly without changing its target", ctx do
    {state, [{buffer, tab_id}]} = state_with_files(ctx, ["dirty-last"])
    :ok = Buffer.insert_text(buffer, "changed ")
    content = Buffer.content(buffer)
    request_id = register_wait(buffer, ctx.tmp, "dirty-last")
    monitor = Process.monitor(buffer)

    refused = GuiActionHandler.dispatch(state, {:close_tab, tab_id})

    assert TabBar.get(tab_bar(refused), tab_id)
    assert tab_bar(refused).active_id == tab_id
    assert refused.workspace.buffers.active == buffer
    assert Buffer.content(buffer) == content and Buffer.dirty?(buffer)

    assert refused.shell_runtime.state.notice.message ==
             "Buffer has unsaved changes. Use SPC b X to force kill."

    assert wait_pending?(buffer, request_id)
    refute_received %WaitRequestCompletion{request_id: ^request_id}
    refute_received {:DOWN, ^monitor, :process, ^buffer, _reason}
  end

  test "closing the last clean file restores a retained buffer without destroying it", ctx do
    {state, [{closing, tab_id}]} = state_with_files(ctx, ["closing"])
    retained = file_buffer(ctx, "retained")
    retained_monitor = Process.monitor(retained)
    closing_monitor = Process.monitor(closing)
    request_id = register_wait(closing, ctx.tmp, "closing")

    buffers = Buffers.add_background(state.workspace.buffers, retained)
    state = %{state | workspace: SessionState.set_buffers(state.workspace, buffers)}
    closed = GuiActionHandler.dispatch(state, {:close_tab, tab_id})

    assert_receive %WaitRequestCompletion{request_id: ^request_id, outcome: :accepted}
    assert_receive {:DOWN, ^closing_monitor, :process, ^closing, :normal}
    assert closed.workspace.buffers.active == retained
    assert closed.workspace.buffers.list == [retained]
    assert TabBar.get(tab_bar(closed), tab_id)
    assert Buffer.content(retained) == "retained"
    refute_received {:DOWN, ^retained_monitor, :process, ^retained, _reason}
  end

  test "closing an inactive workspace's last clean file restores the active tab context", ctx do
    {state, [{active, active_id}, {target, target_id}]} =
      state_with_files(ctx, ["active", "target"])

    retained = file_buffer(ctx, "retained-background")
    retained_monitor = Process.monitor(retained)
    target_monitor = Process.monitor(target)

    target_buffers =
      state.workspace.buffers
      |> Buffers.add_background(retained)
      |> Buffers.replace_list([target, retained], 0)

    target_workspace = SessionState.set_buffers(state.workspace, target_buffers)
    target_context = TabContext.snapshot(target_workspace)
    {bar_with_workspace, target_workspace_model} = TabBar.add_workspace(tab_bar(state), "Target")

    bar_with_workspace =
      bar_with_workspace
      |> TabBar.update_context(target_id, target_context)
      |> TabBar.move_tab_to_workspace(target_id, target_workspace_model.id)

    state = %{state | workspace: target_workspace} |> install_tab_bar(bar_with_workspace)
    state = TabWorkflow.switch(state, active_id)
    :ok = Buffer.move_to(active, {0, 3})

    active_workspace = state.workspace
    active_snapshot = TabBar.get(tab_bar(state), active_id).context

    closed = GuiActionHandler.dispatch(state, {:close_tab, target_id})

    assert_receive {:DOWN, ^target_monitor, :process, ^target, :normal}
    assert tab_bar(closed).active_id == active_id
    assert closed.workspace.buffers == active_workspace.buffers
    assert closed.workspace.windows == active_workspace.windows
    assert closed.workspace.editing == active_workspace.editing
    assert Buffer.cursor(active) == {0, 3}
    assert TabBar.get(tab_bar(closed), active_id).context == active_snapshot

    retained_context = TabBar.get(tab_bar(closed), target_id).context
    assert retained_context.buffers.active == retained
    assert retained_context.buffers.list == [retained]
    assert Process.alive?(retained) and Buffer.content(retained) == "retained-background"
    refute_received {:DOWN, ^retained_monitor, :process, ^retained, _reason}
  end

  test "closing the only clean file destroys it and enters the launchpad", ctx do
    {state, [{buffer, tab_id}]} = state_with_files(ctx, ["clean-last"])
    request_id = register_wait(buffer, ctx.tmp, "clean-last")
    monitor = Process.monitor(buffer)

    closed = GuiActionHandler.dispatch(state, {:close_tab, tab_id})

    assert_receive %WaitRequestCompletion{request_id: ^request_id, outcome: :accepted}
    assert_receive {:DOWN, ^monitor, :process, ^buffer, :normal}
    assert closed.workspace.buffers.active == nil and closed.workspace.buffers.list == []
    assert %Launchpad{} = closed.workspace.launchpad
    assert tab_bar(closed).tabs == [] and tab_bar(closed).active_id == nil
  end

  test "closing inactive and active agent tabs stays bound to each requested ID", ctx do
    {state, [{file, file_id}]} = state_with_files(ctx, ["file"])
    {state, first_agent_id} = add_agent_tab(state, "Agent one")
    {state, second_agent_id} = add_agent_tab(state, "Agent two")

    inactive_closed = GuiActionHandler.dispatch(state, {:close_tab, first_agent_id})

    assert TabBar.get(tab_bar(inactive_closed), first_agent_id) == nil
    assert TabBar.get(tab_bar(inactive_closed), second_agent_id)
    assert tab_bar(inactive_closed).active_id == file_id
    assert inactive_closed.workspace.buffers.active == file

    active_agent = TabWorkflow.switch(inactive_closed, second_agent_id)
    assert tab_bar(active_agent).active_id == second_agent_id

    active_closed = GuiActionHandler.dispatch(active_agent, {:close_tab, second_agent_id})

    assert TabBar.get(tab_bar(active_closed), second_agent_id) == nil
    assert tab_bar(active_closed).active_id == file_id
    assert active_closed.workspace.buffers.active == file
    assert Process.alive?(file)
  end

  test "closing an inactive agent tab preserves active tab operations", ctx do
    {state, [{file, file_id}]} = state_with_files(ctx, ["file"])
    {state, agent_id} = add_agent_tab(state, "Inactive agent")
    {state, operations} = track_tab_operations(state, file_id)

    closed = GuiActionHandler.dispatch(state, {:close_tab, agent_id})

    assert tab_bar(closed).active_id == file_id
    assert closed.workspace.buffers.active == file
    assert_tab_operations_preserved(closed, file_id, operations)
  end

  defp state_with_files(ctx, names) do
    [{_first_name, first_buffer} | rest] = Enum.map(names, &{&1, file_buffer(ctx, &1)})

    state =
      Startup.build_initial_state(
        port_manager: nil,
        options_server: ctx.options,
        buffer: first_buffer,
        width: 60,
        height: 20,
        editing_model: :vim,
        session_dir: Path.join(ctx.tmp, "sessions")
      )

    first = {first_buffer, tab_bar(state).active_id}

    {state, opened} =
      Enum.reduce(rest, {state, [first]}, fn {_name, buffer}, {current, acc} ->
        next = Commands.add_buffer(current, buffer)
        {next, acc ++ [{buffer, tab_bar(next).active_id}]}
      end)

    {state, opened}
  end

  defp file_buffer(ctx, name) do
    path = Path.join(ctx.tmp, "#{name}.txt")
    File.write!(path, name)

    start_supervised!(
      {Buffer, file_path: path, options_server: ctx.options},
      id: {Buffer, make_ref()}
    )
  end

  defp add_agent_tab(state, label) do
    tab_bar = tab_bar(state)
    {tab_bar, tab} = TabBar.insert(tab_bar, :agent, label)

    context =
      TabContext.new_agent(
        state.frontend.terminal_viewport,
        state.workspace.file_tree.project_root
      )

    tab_bar = TabBar.update_context(tab_bar, tab.id, context)
    {install_tab_bar(state, tab_bar), tab.id}
  end

  defp install_tab_bar(state, tab_bar) do
    shell_state = TraditionalState.install_tab_bar(Runtime.state(state.shell_runtime), tab_bar)
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end

  defp tab_bar(state), do: state.shell_runtime.state.tab_bar

  defp register_wait(buffer, tmp, name) do
    request_id = "targeted-close-#{name}-#{System.unique_integer([:positive])}"
    :ok = WaitRequests.register(buffer, Path.join(tmp, "#{name}.txt"), request_id, self())
    request_id
  end

  defp track_tab_operations(state, tab_id) do
    {references_feedback, references} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :lsp_references,
        "lsp:references:active.ex",
        "Finding references…",
        cancelable?: false,
        replace?: false
      )

    feedback = Feedback.accept_operation_feedback(state.feedback, references_feedback)

    {rename_feedback, rename} =
      OperationFeedback.start(
        feedback.operation_feedback,
        :lsp_rename,
        "lsp:rename:active.ex",
        "Renaming…",
        cancelable?: false,
        replace?: false
      )

    feedback = Feedback.accept_operation_feedback(feedback, rename_feedback)

    lsp =
      state.lsp
      |> LSPState.track_operation_request(make_ref(), :references, references.id, tab_id)
      |> LSPState.track_operation_request(make_ref(), :rename, rename.id, tab_id)

    {%{state | feedback: feedback, lsp: lsp}, [references, rename]}
  end

  defp assert_tab_operations_preserved(state, tab_id, operations) do
    {requests, _lsp} = LSPState.take_operation_requests_for_tab(state.lsp, tab_id)
    assert Enum.count(requests) == 2

    Enum.each(operations, fn operation ->
      assert {:ok, ^operation} =
               OperationFeedback.fetch(state.feedback.operation_feedback, operation.id)
    end)
  end

  defp wait_pending?(buffer, request_id) do
    case :sys.get_state(WaitRequests).requests do
      %{^buffer => %{entries: entries}} -> Map.has_key?(entries, request_id)
      _requests -> false
    end
  end
end
