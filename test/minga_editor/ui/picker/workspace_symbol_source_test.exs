defmodule MingaEditor.UI.Picker.WorkspaceSymbolSourceTest do
  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.LSP.SyncServer
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.PickerUI
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FetchEffect
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.WorkspaceSymbolSource

  @moduletag :tmp_dir

  describe "server-side query" do
    setup do
      state = state_with_scheduler()
      client = start_fake_client(self())
      buffer = state.workspace.buffers.active
      SyncServer.put_clients(buffer, [client])
      on_exit(fn -> :ets.delete(SyncServer.registry_table(), buffer) end)
      %{state: state}
    end

    test "an empty query opens the picker without asking the server", %{state: state} do
      opened = PickerUI.open(state, WorkspaceSymbolSource)

      assert_receive {:effect_result, _scheduler, %Outcome{value: {:completed, _}} = outcome}
      refute_received {:symbol_request, _query, _caller, _ref}

      {applied, _outcome} = FetchEffect.apply(opened, outcome)
      assert picker_ui(applied).load_status == :ready
      assert picker_ui(applied).picker.items == []
    end

    test "opening over another picker with a query still settles", %{state: state} do
      other =
        %PickerState{
          picker: [] |> Picker.new(title: "Other", max_visible: 5) |> Picker.filter("abc"),
          source: MingaEditor.UI.Picker.CommandSource
        }

      covered = ModalWorkflow.open(state, {:picker, PickerPayload.new(other)})
      opened = PickerUI.open(covered, WorkspaceSymbolSource)

      assert_receive {:effect_result, _scheduler, %Outcome{value: {:completed, _}} = outcome}
      refute_received {:symbol_request, _query, _caller, _ref}

      {applied, %Outcome{value: {:completed, _}}} = FetchEffect.apply(opened, outcome)
      assert picker_ui(applied).load_status == :ready
    end

    test "each query edit asks the server with that query and keeps every server row in order",
         %{state: state} do
      opened = open_settled(state)

      typed = PickerUI.replace_query(opened, picker_ui(opened).query_generation, 1, "fo")
      assert_receive {:symbol_request, "fo", caller, ref}

      # The server matched "Bar" through its container, which a local fuzzy filter on "fo" would hide.
      send(caller, {:lsp_response, ref, {:ok, [symbol("Foo.zeta"), symbol("Bar", "Foo")]}})

      assert_receive {:effect_result, _scheduler, %Outcome{value: {:completed, _}} = outcome}
      {applied, _outcome} = FetchEffect.apply(typed, outcome)

      assert picker_ui(applied).picker.query == "fo"

      names =
        Enum.map(
          picker_ui(applied).picker.filtered,
          &(&1.label |> String.split(" ") |> List.last())
        )

      assert names == ["Foo.zeta", "Bar"]
    end

    test "typed and deleted keys ask the server for the edited query", %{state: state} do
      opened = open_settled(state)

      typed = PickerUI.handle_key(opened, ?f, 0)
      assert_receive {:symbol_request, "f", caller, ref}
      send(caller, {:lsp_response, ref, {:ok, [symbol("Foo")]}})
      assert_receive {:effect_result, _scheduler, %Outcome{value: {:completed, _}} = outcome}
      {settled, _outcome} = FetchEffect.apply(typed, outcome)
      assert [_foo] = picker_ui(settled).picker.filtered

      pasted = PickerUI.append_query(settled, "o")
      assert_receive {:symbol_request, "fo", _caller, _ref}

      deleted = PickerUI.handle_key(pasted, 127, 0)
      assert picker_ui(deleted).picker.query == "f"
      assert_receive {:symbol_request, "f", _caller, _ref}
    end

    test "a superseded query loses its worker and its late result is stale", %{state: state} do
      opened = open_settled(state)
      generation = picker_ui(opened).query_generation

      first = PickerUI.replace_query(opened, generation, 1, "f")
      assert_receive {:symbol_request, "f", first_worker, _first_ref}
      monitor = Process.monitor(first_worker)
      first_revision = picker_ui(first).fetch_revision

      second = PickerUI.replace_query(first, generation, 2, "fo")
      assert_receive {:DOWN, ^monitor, :process, ^first_worker, _reason}
      assert_receive {:symbol_request, "fo", _second_worker, _second_ref}

      late_items = [%Item{id: {"/tmp/late.ex", 0, 0}, label: "Late"}]

      late =
        WorkspaceSymbolSource
        |> FetchEffect.request(nil, Context.from_editor_state(first), first_revision)
        |> Outcome.completed({:ok, late_items, Candidate.from_items(late_items), %{}})

      assert {^second, %Outcome{value: {:stale, _reason}}} = FetchEffect.apply(second, late)
    end
  end

  test "selecting a symbol in the active file still routes buffer activation", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "active-symbol.ex") |> Path.expand()
    File.write!(path, "defmodule ActiveSymbol do\nend\n")

    {:ok, buffer} = BufferProcess.start_link(file_path: path)
    stale_label = "stale-label.ex"

    state =
      buffer
      |> active_file_state(stale_label)
      |> then(fn state ->
        %{
          state
          | workspace:
              SessionState.set_editing(state.workspace, %{
                state.workspace.editing
                | last_jump_pos: nil
              })
        }
      end)

    item = %Item{id: {path, 1, 2}, label: "ActiveSymbol"}
    new_state = WorkspaceSymbolSource.on_select(item, state)

    assert new_state.workspace.buffers.active == buffer
    assert Buffer.cursor(buffer) == {1, 2}
    assert new_state.workspace.editing.last_jump_pos == {0, 0}
    assert TabBar.active(new_state.shell_runtime.state.tab_bar).label == "active-symbol.ex"
    refute TabBar.active(new_state.shell_runtime.state.tab_bar).label == stale_label
  end

  defp state_with_scheduler do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec({EffectScheduler, task_supervisor: task_supervisor}, id: make_ref())
      )

    :ok = EffectScheduler.attach(scheduler, self())
    %{base_state(rendering: :disabled) | effect_scheduler: scheduler}
  end

  # Stands in for an LSP client: forwards workspace/symbol requests to the test, which replies to the caller.
  defp start_fake_client(test_pid) do
    spawn_link(fn -> fake_client_loop(test_pid) end)
  end

  defp fake_client_loop(test_pid) do
    receive do
      {:"$gen_cast", {:async_request, "workspace/symbol", %{"query" => query}, caller, ref}} ->
        send(test_pid, {:symbol_request, query, caller, ref})
        fake_client_loop(test_pid)
    end
  end

  defp open_settled(state) do
    opened = PickerUI.open(state, WorkspaceSymbolSource)
    assert_receive {:effect_result, _scheduler, %Outcome{value: {:completed, _}} = outcome}
    {settled, _outcome} = FetchEffect.apply(opened, outcome)
    settled
  end

  defp picker_ui(state) do
    {:picker, %{picker_ui: picker_ui}} = state.shell_runtime.state.modal
    picker_ui
  end

  defp symbol(name, container \\ "") do
    %{
      "name" => name,
      "kind" => 12,
      "containerName" => container,
      "location" => %{
        "uri" => "file:///tmp/workspace_symbol_test.ex",
        "range" => %{"start" => %{"line" => 0, "character" => 0}}
      }
    }
  end

  defp active_file_state(buffer, stale_label) do
    state = base_state(content: "scratch")
    buffers = %Buffers{active: buffer, list: [buffer], active_index: 0}
    workspace = SessionState.set_buffers(state.workspace, buffers)

    tab = Tab.new_file(1, stale_label) |> Tab.set_context(TabContext.from_workspace(workspace))
    tab_bar = %TabBar{tabs: [tab], active_id: 1, next_id: 2}
    shell_state = ShellState.install_tab_bar(state.shell_runtime.state, tab_bar)

    %{
      state
      | workspace: workspace,
        shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end
end
