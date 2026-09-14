defmodule MingaEditor.PickerUITest do
  @moduledoc "Tests PickerUI picker-state transitions and orchestration."

  use ExUnit.Case, async: false

  alias Minga.Project
  alias Minga.Project.Root
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Input.Picker, as: PickerInput
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.RenderModel.UI.PickerBuilder
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FetchEffect
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ProjectFileCandidate
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  defp marked_buffer_picker do
    [
      %Item{id: 0, label: "alpha"},
      %Item{id: 1, label: "beta"},
      %Item{id: 2, label: "gamma"}
    ]
    |> Picker.new(title: "Switch buffer", max_visible: 10)
    |> Picker.move_down()
    |> Picker.toggle_mark()
    |> Picker.move_down()
    |> Picker.toggle_mark()
  end

  defp picker_state_with_buffers([first_content | rest]) do
    state = TestHelpers.base_state(content: first_content)

    buffers =
      Enum.reduce(rest, state.workspace.buffers, fn content, acc ->
        {:ok, pid} = BufferProcess.start_link(content: content)
        Buffers.add_background(acc, pid)
      end)

    picker_state = %PickerState{
      picker: marked_buffer_picker(),
      source: MingaEditor.UI.Picker.BufferSource,
      restore: 0
    }

    state
    |> then(fn state ->
      %{
        state
        | workspace:
            then(state.workspace, fn workspace ->
              MingaEditor.Session.State.set_buffers(workspace, buffers)
            end)
      }
    end)
    |> ModalWorkflow.open({:picker, PickerPayload.new(picker_state)})
  end

  defp preview_promotion_state do
    {:ok, original_buf} = BufferProcess.start_link(content: "original")
    {:ok, preview_buf} = BufferProcess.start_link(content: "preview")
    win_id = 1
    original_window = Window.new(win_id, original_buf, 24, 80)
    preview_window = Window.show_buffer(original_window, preview_buf)

    original_workspace = %SessionState{
      editing: VimState.new(),
      buffers: %Buffers{active: original_buf, list: [original_buf], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => original_window},
        active: win_id,
        next_id: win_id + 1
      }
    }

    preview_workspace = %{
      original_workspace
      | buffers: %Buffers{active: preview_buf, list: [original_buf, preview_buf], active_index: 1},
        windows: %{original_workspace.windows | map: %{win_id => preview_window}}
    }

    tab = Tab.new_file(1, "original.ex")
    tb = TabBar.new(tab)
    tb = TabBar.update_context(tb, 1, SessionState.to_tab_context(original_workspace))

    picker = Picker.new([%Item{id: "preview", label: "preview.ex"}], title: "Files")

    picker_state = %PickerState{
      picker: picker,
      source: MingaEditor.UI.Picker.FileSource,
      restore: 0
    }

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: preview_workspace,
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          %ShellState{tab_bar: tb, modal: {:picker, PickerPayload.new(picker_state)}}
        )
    }

    {state, original_buf, preview_buf}
  end

  # A live-preview source used to prove that rapid typing through the input
  # path keeps preview/selection working against a large candidate set. Each
  # preview records the previewed item id into editor state so tests can assert
  # the applied result still drives on_select/2.
  defmodule LargePreviewSource do
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "Large preview"

    @impl true
    def candidates(_ctx), do: []

    @impl true
    def on_select(%Item{id: id}, state), do: Map.put(state, :previewed_id, id)

    @impl true
    def on_cancel(state), do: state

    @impl true
    def live_preview?, do: true
  end

  defmodule BlockingAsyncSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "Blocking async"

    @impl true
    def candidates(_ctx), do: []

    @impl true
    def async?, do: true

    @impl true
    def async_fetch(%{picker_ui: %{context: %{test_pid: test_pid}}}) do
      send(test_pid, {:blocking_picker_started, self()})

      receive do
        :release_blocking_picker -> {:ok, [], %{}}
      end
    end

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state
  end

  defmodule NoBulkActionsSource do
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "No bulk actions"

    @impl true
    def candidates(%{picker_ui: %{context: %{items: items}}}) when is_list(items), do: items

    def candidates(_ctx), do: []

    @impl true
    def on_select(%Item{id: id}, state) do
      state
      |> Map.put(:selected_item_id, id)
      |> Map.update(:selection_count, 1, &(&1 + 1))
    end

    @impl true
    def on_cancel(state), do: state

    @impl true
    def actions(_item), do: [{"Open", :open}, {"Delete", :delete}]

    @impl true
    def on_action(:open, %Item{id: id}, state), do: Map.put(state, :action_item_id, id)

    def on_action(:delete, %Item{id: id}, state),
      do: Map.put(state, :action_item_id, {:delete, id})

    def on_action(_action, _item, state), do: state
  end

  defmodule FailingActionSource do
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "Failing action"

    @impl true
    def candidates(_ctx), do: []

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state

    @impl true
    def actions(_item), do: [{"Fail", :fail}]

    @impl true
    def on_action(:fail, %Item{id: id}, %MingaEditor.State{} = state) do
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Action failed for #{id}")
    end
  end

  defmodule NoCancelSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "No cancel"

    @impl true
    def candidates(_ctx), do: [%Item{id: :no_cancel, label: "No cancel"}]

    @impl true
    def on_select(_item, state), do: state
  end

  defp state_with_scheduler do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: task_supervisor},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())
    %{TestHelpers.base_state(rendering: :disabled) | effect_scheduler: scheduler}
  end

  defp with_project_query(state, query) do
    search = MingaEditor.State.Search.set_project_query(state.workspace.search, query)
    %{state | workspace: SessionState.set_search(state.workspace, search)}
  end

  defp picker_state_for_source(state, source, items) do
    picker = items |> Picker.new(title: "Test", max_visible: 10) |> mark_all_picker()

    picker_state = %PickerState{
      picker: picker,
      source: source,
      restore: state.workspace.buffers.active_index
    }

    ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
  end

  defp mark_all_picker(%Picker{items: []} = picker), do: picker

  defp mark_all_picker(%Picker{} = picker) do
    Enum.reduce(1..length(picker.items), picker, fn _, acc ->
      Picker.toggle_mark(acc) |> Picker.move_down()
    end)
  end

  @spec file_picker_state(String.t()) :: {EditorState.t(), String.t(), binary()}
  defp file_picker_state(tmp_dir) do
    project = Path.join(tmp_dir, "find-file-project")
    path = Path.join(project, "kept.bin")
    bytes = <<0, 1, 2, "keep me">>
    File.mkdir_p!(project)
    File.write!(path, bytes)
    {:ok, root} = Minga.Project.Root.directory(project)
    {:ok, candidate} = ProjectFileCandidate.new(root, "kept.bin")

    state = TestHelpers.base_state(content: "initial")

    picker_state = %PickerState{
      picker: Picker.new([%Item{id: candidate, label: "kept.bin"}], title: "Find file"),
      source: FileSource,
      restore: state.workspace.buffers.active_index
    }

    opened = ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
    {opened, path, bytes}
  end

  @spec file_confirmation_state(String.t(), :file | :directory, boolean()) :: map()
  defp file_confirmation_state(tmp_dir, target_kind \\ :file, existing_target? \\ false) do
    project = Path.join(tmp_dir, "confirmation-project")
    origin_path = Path.join(project, "origin.txt")
    preview_path = Path.join(project, "preview-a.txt")
    target_path = Path.join(project, "target-b.txt")
    File.mkdir_p!(project)
    File.write!(origin_path, "origin")
    File.write!(preview_path, "preview A")
    write_confirmation_target!(target_path, target_kind)
    {:ok, root} = Root.directory(project)
    activate_project!(root)

    {:ok, preview_candidate} = ProjectFileCandidate.new(root, "preview-a.txt")
    {:ok, target_candidate} = ProjectFileCandidate.new(root, "target-b.txt")

    {state, origin_buffer} = state_with_origin_file(origin_path, project)

    {state, target_buffer} =
      if existing_target? do
        add_existing_target_buffer(state, target_path)
      else
        {state, nil}
      end

    picker =
      Picker.new(
        [
          %Item{id: target_candidate, label: "target-b.txt"},
          %Item{id: preview_candidate, label: "preview-a.txt"}
        ],
        title: "Find file"
      )

    picker_state = %PickerState{
      picker: picker,
      source: FileSource,
      restore: state.workspace.buffers.active_index
    }

    %{
      state: ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)}),
      origin_buffer: origin_buffer,
      origin_path: origin_path,
      preview_path: preview_path,
      target_buffer: target_buffer,
      target_path: target_path
    }
  end

  @spec write_confirmation_target!(String.t(), :file | :directory) :: :ok
  defp write_confirmation_target!(path, :file), do: File.write!(path, "target B")
  defp write_confirmation_target!(path, :directory), do: File.mkdir!(path)

  @spec state_with_origin_file(String.t(), String.t()) :: {EditorState.t(), pid()}
  defp state_with_origin_file(origin_path, project) do
    state = TestHelpers.base_state(content: "discarded scratch")
    scratch_buffer = state.workspace.buffers.active
    {:ok, origin_buffer} = BufferProcess.start_link(file_path: origin_path)
    active_window = Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)

    windows = %{
      state.workspace.windows
      | map: %{
          state.workspace.windows.active => Window.show_buffer(active_window, origin_buffer)
        }
    }

    workspace =
      state.workspace
      |> SessionState.set_buffers(%Buffers{
        active: origin_buffer,
        list: [origin_buffer],
        active_index: 0
      })
      |> SessionState.set_windows(windows)
      |> SessionState.set_file_tree(%FileTree{project_root: project})

    tab_bar =
      Tab.new_file(1, "origin.txt")
      |> TabBar.new(project)
      |> TabBar.update_context(1, SessionState.to_tab_context(workspace))

    shell_state = ShellState.install_tab_bar(state.shell_runtime.state, tab_bar)
    stop_pid(scratch_buffer)

    {%{
       state
       | workspace: workspace,
         shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
     }, origin_buffer}
  end

  @spec add_existing_target_buffer(EditorState.t(), String.t()) :: {EditorState.t(), pid()}
  defp add_existing_target_buffer(state, target_path) do
    {:ok, target_buffer} = BufferProcess.start_link(file_path: target_path)
    buffers = Buffers.add_background(state.workspace.buffers, target_buffer)
    state = %{state | workspace: SessionState.set_buffers(state.workspace, buffers)}

    {state, target_buffer}
  end

  @spec preview_a(EditorState.t()) :: EditorState.t()
  defp preview_a(state), do: PickerUI.handle_key(state, ?n, MingaEditor.Input.mod_ctrl())

  @spec select_target(EditorState.t()) :: EditorState.t()
  defp select_target(state), do: PickerUI.handle_key(state, ?p, MingaEditor.Input.mod_ctrl())

  @spec choose_open_action(EditorState.t()) :: EditorState.t()
  defp choose_open_action(state) do
    state
    |> PickerUI.handle_key(?o, MingaEditor.Input.mod_ctrl())
    |> PickerUI.handle_key(13, 0)
  end

  @spec tab_buffer_paths(EditorState.t()) :: [String.t() | nil]
  defp tab_buffer_paths(state) do
    state.shell_runtime.state.tab_bar.tabs
    |> Enum.map(fn tab -> Minga.Buffer.file_path(tab.context.buffers.active) end)
  end

  @spec flush_file_visits() :: [String.t()]
  defp flush_file_visits do
    _ = :sys.get_state(Project)
    Project.recent_files()
  end

  @spec activate_project!(Root.t()) :: :ok
  defp activate_project!(%Root{path: path} = root) do
    Minga.Events.subscribe(:project_rebuilt)
    assert {:ok, snapshot} = Project.activate(root)

    if snapshot.rebuilding? do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^path}},
                     5_000
    end

    _ = :sys.get_state(Project)
    :ok
  end

  @spec restore_project(Minga.Project.WorkspaceSnapshot.t() | nil) :: :ok
  defp restore_project(nil) do
    Project.close()
    _ = :sys.get_state(Project)
    :ok
  end

  defp restore_project(%Minga.Project.WorkspaceSnapshot{root: root}) do
    Project.close()
    _ = :sys.get_state(Project)
    _ = Project.activate(root)
    :ok
  end

  @spec stop_added_buffers(EditorState.t(), EditorState.t()) :: :ok
  defp stop_added_buffers(result_state, initial_state) do
    initial_buffers = MapSet.new(initial_state.workspace.buffers.list)

    result_state.workspace.buffers.list
    |> Enum.reject(&MapSet.member?(initial_buffers, &1))
    |> Enum.each(&stop_pid/1)
  end

  @spec stop_pid(pid()) :: :ok
  defp stop_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  describe "picker cancel" do
    test "Escape closes a picker whose source omits on_cancel/1 without changing editor state" do
      state = TestHelpers.base_state(rendering: :disabled)
      opened = PickerUI.open(state, NoCancelSource)

      canceled = PickerUI.handle_key(opened, 27, 0)

      assert canceled.shell_runtime.state.modal == :none
      assert canceled.workspace == state.workspace
    end
  end

  describe "async picker lifecycle" do
    test "replacing and closing a picker cancel scheduler-owned fetches" do
      state = state_with_scheduler()
      first = PickerUI.open(state, BlockingAsyncSource, %{test_pid: self()})
      assert_receive {:blocking_picker_started, first_worker}
      first_monitor = Process.monitor(first_worker)

      replacement = PickerUI.open(first, BlockingAsyncSource, %{test_pid: self()})
      assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, _reason}
      assert_receive {:blocking_picker_started, replacement_worker}
      replacement_monitor = Process.monitor(replacement_worker)

      closed = PickerUI.close(replacement)
      assert_receive {:DOWN, ^replacement_monitor, :process, ^replacement_worker, _reason}
      assert closed.shell_runtime.state.modal == :none
      assert EffectScheduler.stats(closed.effect_scheduler).admitted == 0
    end

    test "closing terminalizes a completed candidate before it can be claimed" do
      state = state_with_scheduler()
      opened = PickerUI.open(state, BlockingAsyncSource, %{test_pid: self()})
      assert_receive {:blocking_picker_started, worker}
      send(worker, :release_blocking_picker)

      assert_receive {:effect_result, scheduler,
                      %Outcome{value: {:completed, _result}, request: request} = outcome}

      assert scheduler == opened.effect_scheduler
      closed = PickerUI.close(opened)

      assert EffectScheduler.claim(scheduler, outcome) == {:error, :not_pending}
      assert EffectScheduler.cancel(scheduler, request.id) == {:error, :not_found}
      assert closed.shell_runtime.state.modal == :none
    end
  end

  describe "bulk picker actions" do
    test "C-o shows source bulk actions when items are marked" do
      state = picker_state_with_buffers(["alpha", "beta", "gamma"])

      new_state = PickerUI.handle_key(state, ?o, MingaEditor.Input.mod_ctrl())

      {:picker, %{picker_ui: %{action_menu: {actions, 0, _item}}}} =
        new_state.shell_runtime.state.modal

      assert actions == [
               {"Kill all marked",
                {:bulk, :kill_marked, Picker.marked_items(marked_buffer_picker())}}
             ]
    end

    test "Enter applies source bulk select when items are marked" do
      state = picker_state_with_buffers(["alpha", "beta", "gamma"])

      new_state = PickerUI.handle_key(state, 13, 0)

      assert new_state.shell_runtime.state.modal == :none
      assert Enum.count(new_state.workspace.buffers.list) == 1
      assert Minga.Buffer.content(new_state.workspace.buffers.active) == "alpha"
    end
  end

  describe "branch delete shortcut" do
    test "plain d remains query input for a generic picker that exposes delete actions" do
      picker =
        Picker.new([%Item{id: :delete_me, label: "Delete me"}], title: "Delete Action Test")

      picker_state = %PickerState{
        picker: picker,
        source: Minga.Test.DeleteActionPickerSource,
        restore: 0
      }

      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{port_manager: nil},
        workspace: %SessionState{editing: VimState.new()},
        shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            %ShellState{modal: {:picker, PickerPayload.new(picker_state)}}
          )
      }

      result = PickerUI.handle_key(state, ?d, 0)
      {:picker, %{picker_ui: picker_ui}} = result.shell_runtime.state.modal

      assert picker_ui.picker.query == "d"
      assert result.shell_runtime.state.notice.message == nil
      assert result.workspace.editing.mode == :normal
    end

    test "C-d invokes a generic source-declared delete action" do
      picker =
        Picker.new([%Item{id: :delete_me, label: "Delete me"}], title: "Delete Action Test")

      picker_state = %PickerState{
        picker: picker,
        source: Minga.Test.DeleteActionPickerSource,
        restore: 0
      }

      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{port_manager: nil},
        workspace: %SessionState{editing: VimState.new()},
        shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            %ShellState{modal: {:picker, PickerPayload.new(picker_state)}}
          )
      }

      result = PickerUI.handle_key(state, ?d, MingaEditor.Input.mod_ctrl())

      assert result.shell_runtime.state.modal == :none
      assert result.shell_runtime.state.notice.message == "Deleted via action"
    end
  end

  describe "Find file actions" do
    @tag :tmp_dir
    test "C-d is a no-op that keeps the picker open and preserves disk bytes", %{
      tmp_dir: tmp_dir
    } do
      {state, path, bytes} = file_picker_state(tmp_dir)

      assert {:handled, result} =
               PickerInput.handle_key(state, ?d, MingaEditor.Input.mod_ctrl())

      assert result == state
      assert {:picker, %{picker_ui: %{action_menu: nil}}} = result.shell_runtime.state.modal
      assert File.read!(path) == bytes
    end

    @tag :tmp_dir
    test "Actions offers only Open and dispatches it without changing disk bytes", %{
      tmp_dir: tmp_dir
    } do
      {state, path, bytes} = file_picker_state(tmp_dir)

      assert {:handled, menu_state} =
               PickerInput.handle_key(state, ?o, MingaEditor.Input.mod_ctrl())

      assert {:picker, %{picker_ui: %{action_menu: {[{"Open", :open}], 0, _item}}}} =
               menu_state.shell_runtime.state.modal

      model =
        menu_state
        |> MingaEditor.Frontend.Emit.Context.from_editor_state()
        |> PickerBuilder.build()

      assert model.action_menu.actions == ["Open"]
      refute "Delete" in model.action_menu.actions
      assert File.read!(path) == bytes

      assert {:handled, opened_state} = PickerInput.handle_key(menu_state, 13, 0)
      on_exit(fn -> stop_added_buffers(opened_state, state) end)

      assert opened_state.shell_runtime.state.modal == :none
      assert Minga.Buffer.file_path(opened_state.workspace.buffers.active) == path
      assert File.read!(path) == bytes
    end
  end

  describe "bulk action fallback for sources without bulk support" do
    test "Enter still performs normal single select when marks exist" do
      state = TestHelpers.base_state(content: "initial")

      picker_state =
        picker_state_for_source(state, NoBulkActionsSource, [
          %Item{id: :first, label: "first"},
          %Item{id: :second, label: "second"}
        ])

      new_state = PickerUI.handle_key(picker_state, 13, 0)

      assert new_state.shell_runtime.state.modal == :none
      assert Map.get(new_state, :selected_item_id) == :first
      refute Map.has_key?(new_state, :bulk_selected)
    end

    test "C-o falls back to normal per-item actions and Enter dispatches on_action" do
      state = TestHelpers.base_state(content: "initial")

      picker_state =
        picker_state_for_source(state, NoBulkActionsSource, [
          %Item{id: :first, label: "first"},
          %Item{id: :second, label: "second"}
        ])

      menu_state = PickerUI.handle_key(picker_state, ?o, MingaEditor.Input.mod_ctrl())

      assert {:picker, %{picker_ui: %{action_menu: {actions, 0, _item}}}} =
               menu_state.shell_runtime.state.modal

      assert Enum.map(actions, &elem(&1, 0)) == ["Open", "Delete"]

      new_state = PickerUI.handle_key(menu_state, 13, 0)

      assert new_state.shell_runtime.state.modal == :none
      assert Map.get(new_state, :action_item_id) == :first
      refute Map.has_key?(new_state, :bulk_selected)
    end

    test "rebuilds candidates, preserves query, and clamps selection" do
      old_items =
        for id <- [:old_one, :old_two, :old_three], do: %Item{id: id, label: "config #{id}"}

      new_items = [%Item{id: :new, label: "config new"}]
      picker = old_items |> Picker.new(title: "Test", max_visible: 10) |> Picker.filter("config")

      picker_state = %PickerState{
        picker: %{picker | selected: 2},
        source: NoBulkActionsSource,
        context: %{items: new_items}
      }

      refreshed =
        TestHelpers.base_state(content: "initial")
        |> ModalWorkflow.open({:picker, PickerPayload.new(picker_state)})
        |> PickerUI.refresh_items()

      {:picker, %{picker_ui: %{picker: refreshed_picker}}} = refreshed.shell_runtime.state.modal

      assert refreshed_picker.items == new_items
      assert Enum.map(refreshed_picker.candidates, & &1.item.id) == [:new]
      assert Enum.map(refreshed_picker.filtered, & &1.id) == [:new]
      assert refreshed_picker.query == "config"
      assert refreshed_picker.selected == 0
    end
  end

  describe "semantic picker activation" do
    test "command palette dispatch executes the exact nonselected command" do
      first = %Item{id: :new_tab, label: "New tab"}
      second = %Item{id: :toggle_file_tree, label: "Toggle file tree"}
      picker = Picker.new([first, second], title: "Commands")

      picker_state =
        %PickerState{
          picker: picker,
          source: MingaEditor.UI.Picker.CommandSource,
          restore: 0
        }
        |> PickerState.refresh_activation_offer()

      state =
        TestHelpers.base_state(content: "initial")
        |> ModalWorkflow.open({:picker, PickerPayload.new(picker_state)})

      assert MingaEditor.Shell.Traditional.SidebarWorkflow.active_id(state) == nil
      generation = picker_state.activation_offer.generation
      result = GuiActionHandler.dispatch(state, {:picker_item_activate, generation, 2})

      assert result.shell_runtime.state.modal == :none
      assert MingaEditor.Shell.Traditional.SidebarWorkflow.active_id(result) == "file_tree"
    end

    @tag :tmp_dir
    test "file finder dispatch opens the exact nonselected file", %{tmp_dir: tmp_dir} do
      first_path = Path.join(tmp_dir, "first.txt")
      second_path = Path.join(tmp_dir, "second.txt")
      File.write!(first_path, "first")
      File.write!(second_path, "second")
      {:ok, root} = Root.directory(tmp_dir)
      {:ok, first} = ProjectFileCandidate.new(root, "first.txt")
      {:ok, second} = ProjectFileCandidate.new(root, "second.txt")

      picker =
        Picker.new(
          [
            %Item{id: first, label: "first.txt"},
            %Item{id: second, label: "second.txt"}
          ],
          title: "Find file"
        )

      picker_state =
        %PickerState{picker: picker, source: FileSource, restore: 0}
        |> PickerState.refresh_activation_offer()

      state =
        TestHelpers.base_state(content: "initial")
        |> ModalWorkflow.open({:picker, PickerPayload.new(picker_state)})

      generation = picker_state.activation_offer.generation
      result = GuiActionHandler.dispatch(state, {:picker_item_activate, generation, 2})
      on_exit(fn -> stop_added_buffers(result, state) end)

      assert result.shell_runtime.state.modal == :none
      assert Minga.Buffer.file_path(result.workspace.buffers.active) == second_path
    end

    test "GUI dispatch activates the exact nonselected offered item once" do
      first = %Item{id: :first, label: "first"}
      second = %Item{id: :second, label: "second"}
      picker = Picker.new([first, second], title: "Test")

      picker_state =
        %PickerState{picker: picker, source: NoBulkActionsSource, restore: 0}
        |> PickerState.refresh_activation_offer()

      state =
        TestHelpers.base_state(content: "initial")
        |> ModalWorkflow.open({:picker, PickerPayload.new(picker_state)})

      generation = picker_state.activation_offer.generation
      result = GuiActionHandler.dispatch(state, {:picker_item_activate, generation, 2})

      assert result.shell_runtime.state.modal == :none
      assert Map.get(result, :selected_item_id) == :second
      assert Map.get(result, :selection_count) == 1

      repeated = GuiActionHandler.dispatch(result, {:picker_item_activate, generation, 2})

      assert Map.get(repeated, :selected_item_id) == :second
      assert Map.get(repeated, :selection_count) == 1

      assert repeated.shell_runtime.state.notice.message ==
               "Picker choice changed; select it again"
    end

    test "stale item activation remains visible and preserves the current query" do
      picker = Picker.new([%Item{id: :first, label: "first"}], title: "Test")

      picker_state =
        %PickerState{picker: picker, source: NoBulkActionsSource, restore: 0}
        |> PickerState.refresh_activation_offer()

      state =
        TestHelpers.base_state(content: "initial")
        |> ModalWorkflow.open({:picker, PickerPayload.new(picker_state)})

      generation = picker_state.activation_offer.generation
      edited = PickerUI.handle_key(state, ?f, 0)
      {:picker, %{picker_ui: replaced_picker}} = edited.shell_runtime.state.modal
      refute replaced_picker.activation_offer.generation == generation
      result = GuiActionHandler.dispatch(edited, {:picker_item_activate, generation, 1})

      assert {:picker, %{picker_ui: %{picker: current}}} = result.shell_runtime.state.modal
      assert current.query == "f"
      assert result.shell_runtime.state.notice.message == "Picker choice changed; select it again"
      refute Map.has_key?(result, :selected_item_id)
    end

    test "GUI dispatch activates the exact action captured when the menu opened" do
      item = %Item{id: :first, label: "first"}
      picker = Picker.new([item], title: "Test")

      picker_state =
        %PickerState{picker: picker, source: NoBulkActionsSource, restore: 0}
        |> PickerState.refresh_activation_offer()

      state =
        TestHelpers.base_state(content: "initial")
        |> ModalWorkflow.open({:picker, PickerPayload.new(picker_state)})
        |> PickerUI.handle_key(?o, MingaEditor.Input.mod_ctrl())

      {:picker, %{picker_ui: live_picker}} = state.shell_runtime.state.modal
      generation = live_picker.activation_offer.generation
      result = GuiActionHandler.dispatch(state, {:picker_action_activate, generation, 2})

      assert result.shell_runtime.state.modal == :none
      assert Map.get(result, :action_item_id) == {:delete, :first}
    end

    test "action activation retains the item captured when the menu opened" do
      first = %Item{id: :first, label: "first"}
      second = %Item{id: :second, label: "second"}
      picker = Picker.new([first, second], title: "Test")

      state =
        TestHelpers.base_state(content: "initial")
        |> ModalWorkflow.open(
          {:picker,
           PickerPayload.new(
             %PickerState{picker: picker, source: NoBulkActionsSource, restore: 0}
             |> PickerState.refresh_activation_offer()
           )}
        )
        |> PickerUI.handle_key(?o, MingaEditor.Input.mod_ctrl())
        |> PickerUI.update_picker(fn picker_state ->
          PickerState.update_picker(picker_state, Picker.select_index(picker_state.picker, 1))
        end)

      {:picker, %{picker_ui: live_picker}} = state.shell_runtime.state.modal
      generation = live_picker.activation_offer.generation
      result = GuiActionHandler.dispatch(state, {:picker_action_activate, generation, 2})

      assert result.shell_runtime.state.modal == :none
      assert Map.get(result, :action_item_id) == {:delete, :first}
    end

    test "action activation preserves the source's existing visible failure behavior" do
      item = %Item{id: :first, label: "first"}
      picker = Picker.new([item], title: "Test")

      state =
        TestHelpers.base_state(content: "initial")
        |> ModalWorkflow.open(
          {:picker,
           PickerPayload.new(
             %PickerState{picker: picker, source: FailingActionSource, restore: 0}
             |> PickerState.refresh_activation_offer()
           )}
        )
        |> PickerUI.handle_key(?o, MingaEditor.Input.mod_ctrl())

      {:picker, %{picker_ui: live_picker}} = state.shell_runtime.state.modal
      generation = live_picker.activation_offer.generation
      result = GuiActionHandler.dispatch(state, {:picker_action_activate, generation, 1})

      assert result.shell_runtime.state.modal == :none
      assert result.shell_runtime.state.notice.message == "Action failed for first"
    end
  end

  describe "file confirmation after preview" do
    @describetag :tmp_dir

    setup do
      original_workspace = Project.snapshot()
      on_exit(fn -> restore_project(original_workspace) end)
      :ok
    end

    test "Open restores the origin before confirming valid B", %{tmp_dir: tmp_dir} do
      fixture = file_confirmation_state(tmp_dir)
      previewed = preview_a(fixture.state)
      assert Minga.Buffer.file_path(previewed.workspace.buffers.active) == fixture.preview_path

      selected = select_target(previewed)
      assert Minga.Buffer.file_path(selected.workspace.buffers.active) == fixture.target_path
      result = choose_open_action(selected)
      on_exit(fn -> stop_added_buffers(result, fixture.state) end)

      assert result.shell_runtime.state.modal == :none
      assert Minga.Buffer.file_path(result.workspace.buffers.active) == fixture.target_path
      assert tab_buffer_paths(result) == [fixture.origin_path, fixture.target_path]
      assert TabBar.count(result.shell_runtime.state.tab_bar) == 2
      assert result.shell_runtime.state.tab_bar.active_id == 2

      assert TabBar.get(result.shell_runtime.state.tab_bar, 1).context.buffers.active ==
               fixture.origin_buffer

      assert result.shell_runtime.state.notice.message == nil
      assert flush_file_visits() == ["target-b.txt"]
    end

    test "Enter restores the origin and reports missing B without promoting A", %{
      tmp_dir: tmp_dir
    } do
      fixture = file_confirmation_state(tmp_dir)
      previewed = preview_a(fixture.state)
      File.rm!(fixture.target_path)
      selected = select_target(previewed)
      assert Minga.Buffer.file_path(selected.workspace.buffers.active) == fixture.preview_path

      result = PickerUI.handle_key(selected, 13, 0)
      on_exit(fn -> stop_added_buffers(result, fixture.state) end)

      assert result.shell_runtime.state.modal == :none
      assert result.workspace.buffers.active == fixture.origin_buffer
      assert tab_buffer_paths(result) == [fixture.origin_path]
      assert result.shell_runtime.state.tab_bar.active_id == 1
      assert result.shell_runtime.state.notice.message == "Could not open target-b.txt"
      assert flush_file_visits() == []
    end

    test "Enter reports an opening failure independently from candidate resolution", %{
      tmp_dir: tmp_dir
    } do
      fixture = file_confirmation_state(tmp_dir, :directory)
      previewed = preview_a(fixture.state)
      selected = select_target(previewed)
      assert Minga.Buffer.file_path(selected.workspace.buffers.active) == fixture.preview_path

      result = PickerUI.handle_key(selected, 13, 0)
      on_exit(fn -> stop_added_buffers(result, fixture.state) end)

      assert result.shell_runtime.state.modal == :none
      assert result.workspace.buffers.active == fixture.origin_buffer
      assert tab_buffer_paths(result) == [fixture.origin_path]
      assert result.shell_runtime.state.tab_bar.active_id == 1
      assert result.shell_runtime.state.notice.message == "Could not open target-b.txt"
      assert flush_file_visits() == []
    end

    test "confirming previewed A creates exactly one proper tab and preserves the origin tab", %{
      tmp_dir: tmp_dir
    } do
      fixture = file_confirmation_state(tmp_dir)
      previewed = preview_a(fixture.state)
      preview_buffer = previewed.workspace.buffers.active
      result = PickerUI.handle_key(previewed, 13, 0)
      on_exit(fn -> stop_added_buffers(result, fixture.state) end)

      assert result.shell_runtime.state.modal == :none
      assert result.workspace.buffers.active == preview_buffer
      assert tab_buffer_paths(result) == [fixture.origin_path, fixture.preview_path]
      assert TabBar.count(result.shell_runtime.state.tab_bar) == 2
      assert result.shell_runtime.state.tab_bar.active_id == 2

      assert TabBar.get(result.shell_runtime.state.tab_bar, 1).context.buffers.active ==
               fixture.origin_buffer

      assert result.shell_runtime.state.notice.message == nil
      assert flush_file_visits() == ["preview-a.txt"]
    end

    test "confirming an already open target creates its missing tab without buffer duplication",
         %{
           tmp_dir: tmp_dir
         } do
      fixture = file_confirmation_state(tmp_dir, :file, true)
      previewed = preview_a(fixture.state)
      selected = select_target(previewed)
      assert selected.workspace.buffers.active == fixture.target_buffer

      result = PickerUI.handle_key(selected, 13, 0)
      on_exit(fn -> stop_added_buffers(result, fixture.state) end)

      assert result.shell_runtime.state.modal == :none
      assert result.workspace.buffers.active == fixture.target_buffer
      assert tab_buffer_paths(result) == [fixture.origin_path, fixture.target_path]
      assert TabBar.count(result.shell_runtime.state.tab_bar) == 2
      assert result.shell_runtime.state.tab_bar.active_id == 2
      assert Enum.count(result.workspace.buffers.list, &(&1 == fixture.target_buffer)) == 1

      assert TabBar.get(result.shell_runtime.state.tab_bar, 1).context.buffers.active ==
               fixture.origin_buffer

      assert result.shell_runtime.state.notice.message == nil
      assert flush_file_visits() == ["target-b.txt"]
    end

    test "Enter with no selected result restores the origin without opening or recording", %{
      tmp_dir: tmp_dir
    } do
      fixture = file_confirmation_state(tmp_dir)

      no_result =
        fixture.state
        |> preview_a()
        |> PickerUI.handle_key(?z, 0)

      result = PickerUI.handle_key(no_result, 13, 0)
      on_exit(fn -> stop_added_buffers(result, fixture.state) end)

      assert result.shell_runtime.state.modal == :none
      assert result.workspace.buffers.active == fixture.origin_buffer
      assert tab_buffer_paths(result) == [fixture.origin_path]
      assert result.shell_runtime.state.tab_bar.active_id == 1
      assert result.shell_runtime.state.notice.message == nil
      assert flush_file_visits() == []
    end

    test "cancellation restores the origin without opening or recording", %{tmp_dir: tmp_dir} do
      fixture = file_confirmation_state(tmp_dir)
      previewed = preview_a(fixture.state)
      result = PickerUI.handle_key(previewed, 27, 0)
      on_exit(fn -> stop_added_buffers(result, fixture.state) end)

      assert result.shell_runtime.state.modal == :none
      assert result.workspace.buffers.active == fixture.origin_buffer
      assert tab_buffer_paths(result) == [fixture.origin_path]
      assert result.shell_runtime.state.tab_bar.active_id == 1
      assert result.shell_runtime.state.notice.message == nil
      assert flush_file_visits() == []
    end
  end

  describe "picker source switching" do
    test "backspace through a mode prefix restores the original source and prompt" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      switched_state = PickerUI.handle_key(state, ?>, 0)
      {:picker, %{picker_ui: switched_pui}} = switched_state.shell_runtime.state.modal
      assert switched_pui.source == MingaEditor.UI.Picker.CommandSource

      assert switched_pui.source_switch ==
               {:switched, MingaEditor.UI.Picker.FileSource, ">"}

      reverted_state = PickerUI.handle_key(switched_state, 127, 0)
      {:picker, %{picker_ui: reverted_pui}} = reverted_state.shell_runtime.state.modal
      assert reverted_pui.source == MingaEditor.UI.Picker.FileSource
      assert reverted_pui.source_switch == :original
    end

    test "hash mode switches from file to project search through async loading" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()
      scheduled = state_with_scheduler()

      state =
        %{state | effect_scheduler: scheduled.effect_scheduler} |> with_project_query("needle")

      switched_state = PickerUI.handle_key(state, ?#, 0)
      {:picker, %{picker_ui: switched_pui}} = switched_state.shell_runtime.state.modal

      assert switched_pui.source == MingaEditor.UI.Picker.ProjectSearchSource

      assert switched_pui.source_switch ==
               {:switched, MingaEditor.UI.Picker.FileSource, "#"}

      assert switched_pui.restore == 0
      assert switched_pui.load_status == :loading
      assert is_reference(switched_pui.fetch_revision)
      assert switched_pui.picker.items == []
      assert EffectScheduler.active?(switched_state.effect_scheduler, FetchEffect)
    end

    test "backspace from hash mode restores file and makes old project search results stale" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()
      scheduled = state_with_scheduler()

      state =
        %{state | effect_scheduler: scheduled.effect_scheduler} |> with_project_query("needle")

      switched_state = PickerUI.handle_key(state, ?#, 0)
      {:picker, %{picker_ui: switched_pui}} = switched_state.shell_runtime.state.modal
      old_revision = switched_pui.fetch_revision

      reverted_state = PickerUI.handle_key(switched_state, 127, 0)
      {:picker, %{picker_ui: reverted_pui}} = reverted_state.shell_runtime.state.modal
      assert reverted_pui.source == MingaEditor.UI.Picker.FileSource
      assert reverted_pui.source_switch == :original
      assert reverted_pui.restore == 0
      refute PickerState.current_fetch?(reverted_pui, old_revision)

      sentinel_items = [%Item{id: :sentinel, label: "sentinel"}]

      stale_outcome =
        MingaEditor.UI.Picker.ProjectSearchSource
        |> FetchEffect.request(nil, Context.from_editor_state(switched_state), old_revision)
        |> Outcome.completed({:ok, sentinel_items, Candidate.from_items(sentinel_items), %{}})

      assert {^reverted_state, %Outcome{value: {:stale, _reason}}} =
               FetchEffect.apply(reverted_state, stale_outcome)

      {:picker, %{picker_ui: reverted_pui}} = reverted_state.shell_runtime.state.modal
      refute Enum.any?(reverted_pui.picker.items, &(&1.id == :sentinel))
    end

    test "typing fix in git log stays in the fuzzy query" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      source = :"Elixir.MingaEditor.PickerUITest.GitLogSource"
      picker = Picker.new([%Item{id: "abc123", label: "abc123"}], title: "Git Log")
      picker_state = %PickerState{picker: picker, source: source}
      state = ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})

      state = Enum.reduce(~c"fix", state, fn cp, acc -> PickerUI.handle_key(acc, cp, 0) end)
      {:picker, %{picker_ui: pui}} = state.shell_runtime.state.modal

      assert pui.source == source
      assert pui.picker.query == "fix"
    end
  end

  describe "native full-query edits" do
    test "accepts the complete query and ignores stale generations and sequences" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      accepted = PickerUI.replace_query(state, 0, 1, "missing")
      {:picker, %{picker_ui: accepted_picker}} = accepted.shell_runtime.state.modal

      assert accepted_picker.picker.query == "missing"
      assert accepted_picker.acknowledged_query_edit_seq == 1

      stale_sequence = PickerUI.replace_query(accepted, 0, 1, "newer")
      stale_generation = PickerUI.replace_query(accepted, 1, 2, "newer")

      assert stale_sequence == accepted
      assert stale_generation == accepted
    end

    test "preserves source-prefix switching and acknowledges the native edit" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      switched = PickerUI.replace_query(state, 0, 1, ">")
      {:picker, %{picker_ui: picker_ui}} = switched.shell_runtime.state.modal

      assert picker_ui.source == MingaEditor.UI.Picker.CommandSource

      assert picker_ui.source_switch ==
               {:switched, MingaEditor.UI.Picker.FileSource, ">"}

      assert picker_ui.picker.query == ""
      assert picker_ui.acknowledged_query_edit_seq == 1
    end

    test "native hash query switches to project search and keeps the pasted query loading" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()
      scheduled = state_with_scheduler()
      state = %{state | effect_scheduler: scheduled.effect_scheduler}
      {:picker, %{picker_ui: initial_pui}} = state.shell_runtime.state.modal

      switched = PickerUI.replace_query(state, initial_pui.query_generation, 1, "#needle")
      {:picker, %{picker_ui: picker_ui}} = switched.shell_runtime.state.modal

      assert picker_ui.source == MingaEditor.UI.Picker.ProjectSearchSource

      assert picker_ui.source_switch ==
               {:switched, MingaEditor.UI.Picker.FileSource, "#"}

      assert picker_ui.picker.query == "needle"
      assert picker_ui.acknowledged_query_edit_seq == 1
      assert picker_ui.load_status == :loading
      assert is_reference(picker_ui.fetch_revision)
    end

    test "applies text pasted after a source prefix to the switched picker" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      switched =
        GuiActionHandler.dispatch(state, {:picker_query_changed, 0, 1, ">open"})

      {:picker, %{picker_ui: picker_ui}} = switched.shell_runtime.state.modal

      assert picker_ui.source == MingaEditor.UI.Picker.CommandSource

      assert picker_ui.source_switch ==
               {:switched, MingaEditor.UI.Picker.FileSource, ">"}

      assert picker_ui.picker.query == "open"
      assert picker_ui.acknowledged_query_edit_seq == 1
    end

    test "normalizes queued native edits that still include the acknowledged source prefix" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      switched = PickerUI.replace_query(state, 0, 1, ">")
      queued = PickerUI.replace_query(switched, 0, 2, ">save")
      {:picker, %{picker_ui: picker_ui}} = queued.shell_runtime.state.modal

      assert picker_ui.source == MingaEditor.UI.Picker.CommandSource
      assert picker_ui.picker.query == "save"
      assert picker_ui.acknowledged_query_edit_seq == 2
    end
  end

  describe "rapid typing against a large candidate set" do
    # Upper bound on results the picker retains per refilter. Mirrors the
    # @result_limit in MingaEditor.UI.Picker; the filtered list must never
    # exceed this no matter how many candidates match, so each keystroke does a
    # fixed amount of result-building work rather than materializing every match.
    @result_limit 200

    defp large_picker_state(source, item_count) do
      state = TestHelpers.base_state(content: "initial")

      items = for i <- 1..item_count, do: %Item{id: i, label: "config_module_#{i}.ex"}
      picker = Picker.new(items, title: source.title(), max_visible: 10)

      picker_state = %PickerState{
        picker: picker,
        source: source,
        restore: state.workspace.buffers.active_index
      }

      ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
    end

    defp type_string(state, string) do
      string
      |> String.to_charlist()
      |> Enum.reduce(state, fn cp, acc -> PickerUI.handle_key(acc, cp, 0) end)
    end

    test "each keystroke keeps the filtered set bounded to the result limit" do
      state = large_picker_state(NoBulkActionsSource, 10_000)

      # Type a query character-by-character through the real input path. Every
      # intermediate query matches all 10k candidates, but the picker must keep
      # only the bounded top-K so per-keystroke work is fixed, not O(n).
      final =
        Enum.reduce(["c", "co", "con", "conf", "config"], state, fn query, _acc ->
          typed = type_string(state, query)
          {:picker, %{picker_ui: %{picker: picker}}} = typed.shell_runtime.state.modal

          assert picker.query == query
          assert Picker.count(picker) == @result_limit
          assert Picker.total(picker) == 10_000
          typed
        end)

      {:picker, %{picker_ui: %{picker: picker}}} = final.shell_runtime.state.modal
      assert Picker.count(picker) == @result_limit
    end

    test "filtered result for a huge set matches the bounded prefix of the full match order" do
      # The input path against 10k candidates must yield exactly the bounded
      # top-K, identical to filtering directly. This guards against the input
      # path quietly diverging from Picker.refilter (e.g. an unbounded code path
      # sneaking back in).
      typed = type_string(large_picker_state(NoBulkActionsSource, 10_000), "config")
      {:picker, %{picker_ui: %{picker: picker}}} = typed.shell_runtime.state.modal

      reference =
        for(i <- 1..10_000, do: %Item{id: i, label: "config_module_#{i}.ex"})
        |> Picker.new()
        |> Picker.filter("config")

      assert Enum.map(picker.filtered, & &1.id) == Enum.map(reference.filtered, & &1.id)
    end

    test "input path stays bounded regardless of candidate-set size" do
      # The work per keystroke is bounded by the result limit, not the candidate
      # count: a 50k set produces the same number of retained results as a 1k
      # set for an all-matching query, so typing cost does not scale with size.
      small = type_string(large_picker_state(NoBulkActionsSource, 1_000), "config")
      large = type_string(large_picker_state(NoBulkActionsSource, 50_000), "config")

      {:picker, %{picker_ui: %{picker: small_picker}}} = small.shell_runtime.state.modal
      {:picker, %{picker_ui: %{picker: large_picker}}} = large.shell_runtime.state.modal

      assert Picker.count(small_picker) == @result_limit
      assert Picker.count(large_picker) == @result_limit
    end

    test "rapid typing through the input path returns promptly for a large set" do
      # Coarse catastrophe guard, not a tight latency SLA (that would be flaky on
      # a shared runner). A full per-keystroke scan-and-sort plus per-candidate
      # match-position computation over 20k candidates would blow well past this
      # ceiling; bounded top-K stays far under it. Measures the whole 6-keystroke
      # input path, then asserts a generous per-keystroke ceiling.
      state = large_picker_state(NoBulkActionsSource, 20_000)
      keystrokes = String.to_charlist("config")

      {micros, final} =
        :timer.tc(fn ->
          Enum.reduce(keystrokes, state, fn cp, acc -> PickerUI.handle_key(acc, cp, 0) end)
        end)

      {:picker, %{picker_ui: %{picker: picker}}} = final.shell_runtime.state.modal
      assert picker.query == "config"
      assert Picker.count(picker) == @result_limit

      per_keystroke_ms = micros / Enum.count(keystrokes) / 1_000

      assert per_keystroke_ms < 250,
             "per-keystroke input path took #{Float.round(per_keystroke_ms, 2)}ms against 20k candidates; expected bounded top-K to stay well under the 250ms catastrophe ceiling"
    end

    test "live preview still runs on_select for the applied result while typing a large set" do
      state = large_picker_state(LargePreviewSource, 10_000)

      typed = type_string(state, "config_module_1.ex")
      {:picker, %{picker_ui: %{picker: picker}}} = typed.shell_runtime.state.modal

      # Selection landed on a real match and preview applied on_select for it.
      assert Picker.selected_item(picker) != nil
      assert Map.get(typed, :previewed_id) == Picker.selected_id(picker)
    end

    test "mode switching is preserved when the first keystroke is a prefix in a large set" do
      # Behavior preservation: typing the command prefix `>` as the first char in
      # a switchable source still swaps sources even with a huge candidate list,
      # rather than being swallowed into a query refilter.
      state = large_file_picker_state(50_000)

      switched = PickerUI.handle_key(state, ?>, 0)
      {:picker, %{picker_ui: pui}} = switched.shell_runtime.state.modal

      assert pui.source == MingaEditor.UI.Picker.CommandSource
      assert pui.source_switch == {:switched, MingaEditor.UI.Picker.FileSource, ">"}
    end

    defp large_file_picker_state(item_count) do
      state = TestHelpers.base_state(content: "initial")

      items = for i <- 1..item_count, do: %Item{id: "file_#{i}.ex", label: "file_#{i}.ex"}
      picker = Picker.new(items, title: "Files", max_visible: 10)

      picker_state = %PickerState{
        picker: picker,
        source: MingaEditor.UI.Picker.FileSource,
        restore: state.workspace.buffers.active_index
      }

      ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
    end
  end
end
