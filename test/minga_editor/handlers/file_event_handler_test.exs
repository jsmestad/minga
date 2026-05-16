defmodule MingaEditor.Handlers.FileEventHandlerTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Handlers.FileEventHandler`.

  Uses `RenderPipeline.TestHelpers.base_state/1` to construct state
  without starting a GenServer.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Git.StatusEntry
  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.Freshness, as: FileTreeFreshness
  alias MingaEditor.Handlers.FileEventHandler
  alias MingaEditor.Shell.Traditional.GitStatus.TuiState
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Workspace.State, as: WorkspaceState

  import MingaEditor.RenderPipeline.TestHelpers

  describe "git_status_changed" do
    test "with open git panel updates panel data and returns render" do
      state = base_state()

      state =
        EditorState.set_git_status_panel(state, %{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      event =
        {:minga_event, :git_status_changed,
         %Minga.Events.GitStatusEvent{
           git_root: "/tmp/repo",
           entries: [%{path: "foo.ex", status: :modified}],
           branch: "develop",
           ahead: 1,
           behind: 0
         }}

      {new_state, effects} = FileEventHandler.handle(state, event)

      panel = EditorState.git_status_panel(new_state)
      assert panel.branch == "develop"
      assert panel.ahead == 1
      assert {:render, 16} in effects
    end

    test "does not create tui state during generic panel refresh" do
      state =
        base_state()
        |> EditorState.set_git_status_panel(%{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      event =
        {:minga_event, :git_status_changed,
         %Minga.Events.GitStatusEvent{
           git_root: "/tmp/repo",
           entries: [%StatusEntry{path: "foo.ex", status: :modified, staged: false}],
           branch: "develop",
           ahead: 1,
           behind: 0
         }}

      {new_state, _effects} = FileEventHandler.handle(state, event)

      panel = EditorState.git_status_panel(new_state)
      refute Map.has_key?(panel, :tui_state)
      assert ShellState.git_status_tui_state(new_state.shell_state) == nil
    end

    test "refreshes existing tui state through the shell state boundary" do
      entries = [%StatusEntry{path: "old.ex", status: :modified, staged: false}]

      state =
        base_state()
        |> EditorState.set_git_status_panel(%{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: entries
        })
        |> EditorState.update_shell_state(
          &ShellState.set_git_status_tui_state(&1, %{TuiState.new() | cursor_index: 99})
        )

      refreshed_entries = [%StatusEntry{path: "new.ex", status: :modified, staged: false}]

      event =
        {:minga_event, :git_status_changed,
         %Minga.Events.GitStatusEvent{
           git_root: "/tmp/repo",
           entries: refreshed_entries,
           branch: "develop",
           ahead: 1,
           behind: 0
         }}

      {new_state, _effects} = FileEventHandler.handle(state, event)

      assert EditorState.git_status_panel(new_state).entries == refreshed_entries
      assert %TuiState{cursor_index: 1} = ShellState.git_status_tui_state(new_state.shell_state)
      refute Map.has_key?(EditorState.git_status_panel(new_state), :tui_state)
    end

    test "without git panel or file tree open is a no-op" do
      state = base_state()

      event =
        {:minga_event, :git_status_changed,
         %Minga.Events.GitStatusEvent{
           git_root: "/tmp/repo",
           entries: [],
           branch: "main",
           ahead: 0,
           behind: 0
         }}

      {new_state, effects} = FileEventHandler.handle(state, event)
      assert new_state == state
      assert effects == []
    end

    test "without git panel open refreshes file tree badges from the event", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "alpha.ex")
      File.write!(file_path, "")
      state = state_with_tree(tmp_dir)

      event =
        {:minga_event, :git_status_changed,
         %Minga.Events.GitStatusEvent{
           git_root: tmp_dir,
           entries: [%StatusEntry{path: "alpha.ex", status: :modified, staged: false}],
           branch: "main",
           ahead: 0,
           behind: 0
         }}

      {new_state, effects} = FileEventHandler.handle(state, event)

      assert new_state.workspace.file_tree.tree.git_status[file_path] == :modified
      assert {:render, 16} in effects
    end
  end

  describe "file tree freshness" do
    @describetag :tmp_dir

    test "file change under the tree root schedules one debounced refresh", %{tmp_dir: tmp_dir} do
      state = state_with_tree(tmp_dir)
      changed_path = Path.join(tmp_dir, "created.ex")

      {_state, effects} = FileEventHandler.handle(state, {:file_changed_on_disk, changed_path})

      assert effects == [{:schedule_file_tree_refresh, 50}]
    end

    test "file change outside the tree root does not refresh", %{tmp_dir: tmp_dir} do
      state = state_with_tree(tmp_dir)
      outside_path = Path.join(tmp_dir <> "_sibling", "created.ex")

      {_state, effects} = FileEventHandler.handle(state, {:file_changed_on_disk, outside_path})

      assert effects == []
    end

    test "file_written under the tree root schedules a debounced refresh", %{tmp_dir: tmp_dir} do
      state = state_with_tree(tmp_dir)
      changed_path = Path.join(tmp_dir, "created_by_agent.ex")

      {_state, effects} =
        FileEventHandler.handle(state, {
          :minga_event,
          :file_written,
          %Minga.Events.FileWrittenEvent{path: changed_path, change_type: :created}
        })

      assert effects == [{:schedule_file_tree_refresh, 50}]
    end

    test "file_written outside the tree root does not refresh", %{tmp_dir: tmp_dir} do
      state = state_with_tree(tmp_dir)
      outside_path = Path.join(tmp_dir <> "_sibling", "created_by_agent.ex")

      {_state, effects} =
        FileEventHandler.handle(state, {
          :minga_event,
          :file_written,
          %Minga.Events.FileWrittenEvent{path: outside_path, change_type: :created}
        })

      assert effects == []
    end

    test "applying repeated refresh effects keeps one pending timer", %{tmp_dir: tmp_dir} do
      state = state_with_tree(tmp_dir)

      first_state = MingaEditor.apply_effects(state, [{:schedule_file_tree_refresh, 1_000}])
      first_ref = first_state.workspace.file_tree.refresh_timer

      second_state =
        MingaEditor.apply_effects(first_state, [{:schedule_file_tree_refresh, 1_000}])

      assert is_reference(first_ref)
      assert second_state.workspace.file_tree.refresh_timer == first_ref
      Process.cancel_timer(first_ref)
    end

    test "refresh timer rescans entries and clears pending timer", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "alpha.ex"), "")

      state =
        tmp_dir
        |> state_with_tree()
        |> FileTreeFreshness.schedule_refresh(make_ref())

      File.write!(Path.join(tmp_dir, "beta.ex"), "")

      {new_state, effects} = FileEventHandler.handle(state, :file_tree_refresh_timer)

      names =
        new_state.workspace.file_tree.tree |> FileTree.visible_entries() |> Enum.map(& &1.name)

      assert "beta.ex" in names
      refute FileTreeFreshness.refresh_scheduled?(new_state)
      assert {:render, 16} in effects
    end

    test "diagnostics under the tree root schedule render", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "alpha.ex")
      state = state_with_tree(tmp_dir)
      uri = Minga.LSP.SyncServer.path_to_uri(file_path)

      {_state, effects} =
        FileEventHandler.handle(state, {
          :minga_event,
          :diagnostics_updated,
          %Minga.Events.DiagnosticsUpdatedEvent{uri: uri, source: :test}
        })

      assert effects == [{:render, 16}]
    end

    test "diagnostics outside the tree root do not render the tree", %{tmp_dir: tmp_dir} do
      state = state_with_tree(tmp_dir)
      uri = Minga.LSP.SyncServer.path_to_uri(Path.join(tmp_dir <> "_sibling", "alpha.ex"))

      {_state, effects} =
        FileEventHandler.handle(state, {
          :minga_event,
          :diagnostics_updated,
          %Minga.Events.DiagnosticsUpdatedEvent{uri: uri, source: :test}
        })

      assert effects == []
    end

    test "buffer changes under the tree root schedule render", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "alpha.ex")
      File.write!(file_path, "alpha")
      {:ok, buffer} = BufferProcess.start_link(file_path: file_path)

      state =
        tmp_dir
        |> state_with_tree()
        |> put_active_buffer(buffer)

      {_state, effects} =
        FileEventHandler.handle(state, {
          :minga_event,
          :buffer_changed,
          %Minga.Events.BufferChangedEvent{buffer: buffer, source: :test}
        })

      assert effects == [{:render, 16}]
    end

    test "buffer changes outside the tree root do not render the tree", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir <> "_sibling", "alpha.ex")
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "alpha")
      {:ok, buffer} = BufferProcess.start_link(file_path: file_path)

      state = state_with_tree(tmp_dir)

      {_state, effects} =
        FileEventHandler.handle(state, {
          :minga_event,
          :buffer_changed,
          %Minga.Events.BufferChangedEvent{buffer: buffer, source: :test}
        })

      assert effects == []
    end

    test "project rebuild changes the visible tree root", %{tmp_dir: tmp_dir} do
      old_root = Path.join(tmp_dir, "old")
      new_root = Path.join(tmp_dir, "new")
      File.mkdir_p!(old_root)
      File.mkdir_p!(new_root)
      File.write!(Path.join(old_root, "old.ex"), "")
      File.write!(Path.join(new_root, "new.ex"), "")

      state = state_with_tree(old_root)

      {new_state, effects} =
        FileEventHandler.handle(state, {
          :minga_event,
          :project_rebuilt,
          %Minga.Events.ProjectRebuiltEvent{root: new_root}
        })

      names =
        new_state.workspace.file_tree.tree |> FileTree.visible_entries() |> Enum.map(& &1.name)

      assert new_state.workspace.file_tree.project_root == Path.expand(new_root)
      assert "new.ex" in names
      refute "old.ex" in names
      assert {:render, 16} in effects
    end
  end

  describe "buffer_saved" do
    test "returns code_lens and inlay_hints effects" do
      state = base_state()

      event =
        {:minga_event, :buffer_saved,
         %Minga.Events.BufferEvent{buffer: self(), path: "/tmp/test.ex"}}

      {_state, effects} = FileEventHandler.handle(state, event)

      assert {:request_code_lens} in effects
      assert {:request_inlay_hints} in effects
    end

    test "returns save_session_deferred in non-headless mode" do
      state = base_state()
      state = %{state | backend: :tui}

      event =
        {:minga_event, :buffer_saved,
         %Minga.Events.BufferEvent{buffer: self(), path: "/tmp/test.ex"}}

      {_state, effects} = FileEventHandler.handle(state, event)

      assert {:save_session_deferred} in effects
    end

    test "does not return save_session_deferred in headless mode" do
      state = base_state()

      event =
        {:minga_event, :buffer_saved,
         %Minga.Events.BufferEvent{buffer: self(), path: "/tmp/test.ex"}}

      {_state, effects} = FileEventHandler.handle(state, event)

      refute {:save_session_deferred} in effects
    end
  end

  describe "git_remote_result" do
    test "returns handle_git_remote_result effect" do
      state = base_state()
      ref = make_ref()
      event = {:git_remote_result, ref, :ok}

      {_state, effects} = FileEventHandler.handle(state, event)

      assert {:handle_git_remote_result, ^ref, :ok} =
               Enum.find(effects, &match?({:handle_git_remote_result, _, _}, &1))
    end
  end

  describe "catch-all" do
    test "unknown messages return no-op" do
      state = base_state()
      {new_state, effects} = FileEventHandler.handle(state, :unknown_file_event)
      assert new_state == state
      assert effects == []
    end
  end

  defp state_with_tree(root) do
    tree = FileTree.new(root)
    file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)

    EditorState.update_workspace(base_state(), &WorkspaceState.set_file_tree(&1, file_tree))
  end

  defp put_active_buffer(state, buffer) do
    buffers = %Buffers{active: buffer, list: [buffer], active_index: 0}
    EditorState.update_workspace(state, &%{&1 | buffers: buffers})
  end
end
