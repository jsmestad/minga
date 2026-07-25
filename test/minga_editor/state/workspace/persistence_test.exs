defmodule MingaEditor.State.Workspace.PersistenceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Project.FileRef
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Identity
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.StateStash
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Agent, as: TabAgent
  alias MingaEditor.State.Tab.File, as: TabFile
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.State.Workspace.Manual, as: WorkspaceManual
  alias MingaEditor.State.Workspace.Persistence
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.WorkspaceWorkflow

  @moduletag :tmp_dir

  test "round-trips the manual workspace with files", %{tmp_dir: dir} do
    {:ok, file_ref} = FileRef.from_path(dir, "lib/a.ex")

    workspace =
      dir
      |> Workspace.new_manual()
      |> Workspace.rename("Project")
      |> Workspace.add_file(file_ref)

    assert :ok = Persistence.write(workspace, dir)
    assert {:ok, restored} = Persistence.read(Persistence.path_for(dir, 0), dir)

    json = Persistence.path_for(dir, 0) |> File.read!() |> JSON.decode!()
    refute Map.has_key?(json, "active_file")

    assert restored.id == 0
    assert restored.kind == :manual
    assert restored.label == "Project"
    assert restored.custom_name == "Project"
    assert Enum.any?(restored.files, &FileRef.equal?(&1, file_ref))
    assert %WorkspaceManual{} = restored.payload
  end

  test "round-trips an agent workspace with custom metadata and review state", %{tmp_dir: dir} do
    {:ok, file_ref} = FileRef.from_path(dir, "lib/agent.ex")
    review = %WorkspaceReview{state: :needs_review, changed_files: [file_ref], in_progress?: true}

    workspace =
      2
      |> Workspace.new_agent("Agent", nil, dir)
      |> Workspace.rename("Investigate parser")
      |> Workspace.set_icon("sparkles")
      |> Workspace.add_file(file_ref)
      |> Workspace.set_review(review)

    assert :ok = Persistence.write(workspace, dir)
    json = Persistence.path_for(dir, 2) |> File.read!() |> JSON.decode!()

    for key <-
          ~w(payload session agent_status remote_session agent_ui project_view pending_catchup_events) do
      refute Map.has_key?(json, key)
    end

    assert {:ok, restored} = Persistence.read(Persistence.path_for(dir, 2), dir)

    assert restored.id == 2
    assert restored.kind == :agent
    assert restored.label == "Investigate parser"
    assert restored.custom_name == "Investigate parser"
    assert restored.icon == "sparkles"

    assert %WorkspaceAgent{session: nil, agent_status: :stopped, project_view: nil} =
             restored.payload

    assert %MingaEditor.Agent.UIState{} = restored.payload.agent_ui
    assert restored.review.state == :needs_review
    refute restored.review.in_progress?
    assert Enum.any?(restored.review.changed_files, &FileRef.equal?(&1, file_ref))
  end

  test "reads legacy workspace JSON with active_file and omits it when re-serializing", %{
    tmp_dir: dir
  } do
    {:ok, file_ref} = FileRef.from_path(dir, "lib/legacy.ex")

    legacy_file =
      Workspace.new_agent(3, "Legacy", nil, dir)
      |> Workspace.add_file(file_ref)
      |> Workspace.to_persisted_map()
      |> Map.fetch!("files")
      |> List.first()

    legacy = %{
      "schema_version" => 1,
      "id" => 3,
      "kind" => "agent",
      "label" => "Legacy",
      "custom_name" => "Legacy",
      "icon" => "cpu",
      "color" => 5_000_000,
      "files" => [legacy_file],
      "active_file" => %{"kind" => "path", "relative_path" => "lib/legacy.ex"},
      "review" => %{"state" => "clean", "changed_files" => [], "conflict_files" => []}
    }

    path = Persistence.path_for(dir, 3)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(legacy))

    assert {:ok, restored} = Persistence.read(path, dir)
    assert restored.id == 3
    assert restored.kind == :agent
    assert restored.label == "Legacy"
    assert Enum.any?(restored.files, &FileRef.equal?(&1, file_ref))
    refute Map.has_key?(Workspace.to_persisted_map(restored), "active_file")
  end

  test "scan skips corrupt JSON and ignores unknown fields", %{tmp_dir: dir} do
    workspace = Workspace.new_agent(1, "Agent", nil, dir)
    assert :ok = Persistence.write(workspace, dir)

    good_path = Persistence.path_for(dir, 1)
    {:ok, data} = good_path |> File.read!() |> JSON.decode()

    data =
      data
      |> Map.put("future_field", %{"ignored" => true})
      |> Map.delete("icon")

    File.write!(good_path, JSON.encode!(data))
    File.write!(Path.join(Path.dirname(good_path), "corrupt.json"), "{not json")

    assert [restored] = Persistence.scan(dir)
    assert restored.id == 1
    assert restored.icon == "cpu"
  end

  test "scan returns empty for an absent workspace directory", %{tmp_dir: dir} do
    assert Persistence.scan(dir) == []
  end

  test "scan warns when the workspace directory cannot be listed", %{tmp_dir: dir} do
    workspace_dir = Path.join([dir, ".minga", "workspaces"])
    File.mkdir_p!(Path.dirname(workspace_dir))
    File.write!(workspace_dir, "not a directory")

    log = capture_log(fn -> assert Persistence.scan(dir) == [] end)

    assert log =~ "Could not scan workspace persistence directory"
    assert log =~ ":enotdir"
  end

  test "atomic write leaves the previous file intact when rename fails", %{tmp_dir: dir} do
    original = Workspace.new_agent(1, "Original", nil, dir)

    updated =
      1
      |> Workspace.new_agent("Original")
      |> Workspace.rename("Updated")
      |> Workspace.with_project_root(dir)

    assert :ok = Persistence.write(original, dir)

    assert {:error, :boom} =
             Persistence.write(updated, dir, rename: fn _tmp, _path -> {:error, :boom} end)

    assert {:ok, restored} = Persistence.read(Persistence.path_for(dir, 1), dir)
    assert restored.label == "Original"
  end

  test "workspace owner mutations stay pure and the workflow writes changed projections", %{
    tmp_dir: dir
  } do
    tab_bar = TabBar.new(Tab.new_file(1, "a.ex"), dir)
    {previous, workspace} = TabBar.add_workspace(tab_bar, "Agent")
    current = TabBar.rename_workspace(previous, workspace.id, "Renamed")
    path = Persistence.path_for(dir, 1)
    refute File.exists?(path)

    assert :ok = WorkspaceWorkflow.persist_tab_bar_changes(tab_bar, current)
    assert {:ok, restored} = Persistence.read(path, dir)
    assert restored.label == "Renamed"
  end

  test "serializes conflict review errors as JSON-safe data", %{tmp_dir: dir} do
    {:ok, file_ref} = FileRef.from_path(dir, "lib/conflict.ex")

    review = %WorkspaceReview{
      state: :conflict,
      changed_files: [file_ref],
      conflict_files: [file_ref],
      last_error: %{conflicts: [{:conflict, "lib/conflict.ex", :concurrent_edit}]}
    }

    workspace =
      1
      |> Workspace.new_agent("Agent", nil, dir)
      |> Workspace.set_review(review)

    assert :ok = Persistence.write(workspace, dir)
    assert {:ok, restored} = Persistence.read(Persistence.path_for(dir, 1), dir)
    assert restored.review.state == :conflict

    assert restored.review.last_error == %{
             "conflicts" => ["{:conflict, \"lib/conflict.ex\", :concurrent_edit}"]
           }
  end

  test "startup tab bar restores persisted workspaces from the project root", %{tmp_dir: dir} do
    workspace = Workspace.new_agent(3, "Persisted Agent", nil, dir)
    assert :ok = Persistence.write(workspace, dir)

    tab_bar = Startup.initial_tab_bar(nil, :editor, dir)

    assert %Workspace{
             label: "Persisted Agent",
             payload: %WorkspaceAgent{session: nil, agent_status: :stopped}
           } =
             TabBar.get_workspace(tab_bar, 3)

    assert TabBar.get_workspace(tab_bar, 0)
    assert tab_bar.next_workspace_id == 4
  end

  test "restored agent workspaces get sessionless tabs so they can be navigated", %{tmp_dir: dir} do
    workspace = Workspace.new_agent(3, "Persisted Agent", nil, dir)
    assert :ok = Persistence.write(workspace, dir)

    tab_bar = Startup.initial_tab_bar(nil, :editor, dir)
    agent_tab = Enum.find(tab_bar.tabs, &(&1.kind == :agent and &1.group_id == 3))

    assert %Tab{label: "Persisted Agent", payload: %TabAgent{session: nil}} = agent_tab

    assert TabBar.switch_to_workspace(tab_bar, 3).active_id == agent_tab.id
  end

  test "null and invalid persisted colors restore workspace defaults", %{tmp_dir: dir} do
    manual_path = Persistence.path_for(dir, 0)
    agent_path = Persistence.path_for(dir, 1)
    File.mkdir_p!(Path.dirname(manual_path))

    File.write!(manual_path, JSON.encode!(%{"id" => 0, "kind" => "manual", "color" => nil}))
    File.write!(agent_path, JSON.encode!(%{"id" => 1, "kind" => "agent", "color" => "bad"}))

    assert {:ok, manual} = Persistence.read(manual_path, dir)
    assert {:ok, agent} = Persistence.read(agent_path, dir)

    assert manual.color == Workspace.new_manual(dir).color
    assert agent.color == Workspace.new_agent(1, "Agent 1", nil, dir).color
  end

  test "workspace workflow writes additions and deletes removals", %{tmp_dir: dir} do
    initial = TabBar.new(Tab.new_file(1, "a.ex"), dir)
    {added, workspace} = TabBar.add_workspace(initial, "Agent")
    path = Persistence.path_for(dir, workspace.id)

    refute File.exists?(path)
    assert :ok = WorkspaceWorkflow.persist_tab_bar_changes(initial, added)
    assert File.exists?(path)

    removed = TabBar.remove_workspace(added, workspace.id)
    refute TabBar.get_workspace(removed, workspace.id)
    assert :ok = WorkspaceWorkflow.persist_tab_bar_changes(added, removed)
    refute File.exists?(path)
  end

  test "stashed Traditional retirement persists cleanup and restores without dead identities", %{
    tmp_dir: dir
  } do
    retired = spawn(fn -> receive do: (:stop -> :ok) end)
    file_ref = FileRef.from_buffer(retired, "scratch")
    initial = TabBar.new(Tab.new_file(1, "scratch"), dir)
    {tab_bar, workspace} = TabBar.add_workspace(initial, "Agent")

    tab_bar =
      tab_bar
      |> TabBar.add_workspace_file(workspace.id, file_ref)

    traditional_entry = Runtime.default_entry()
    traditional = TraditionalState.install_tab_bar(%TraditionalState{}, tab_bar)

    foreign_entry = %Entry{
      id: :foreign,
      source: {:extension, :foreign},
      module: MingaEditor.Test.FakeShell,
      display_name: "Foreign",
      description: "Foreign shell",
      capabilities: [],
      generation: 7
    }

    previous_runtime =
      traditional_entry
      |> Runtime.new(traditional)
      |> Runtime.activate(foreign_entry, %{marker: :foreign})

    previous = %EditorState{
      workspace: %SessionState{},
      shell_runtime: previous_runtime
    }

    path = Persistence.path_for(dir, workspace.id)
    assert :ok = Persistence.write(TabBar.get_workspace(tab_bar, workspace.id), dir)
    assert %{"files" => [_]} = json = path |> File.read!() |> JSON.decode!()
    refute Map.has_key?(json, "active_file")

    current = EditorState.remove_buffer(previous, retired)
    assert Runtime.state(current.shell_runtime) == %{marker: :foreign}

    %StateStash{state: %TraditionalState{tab_bar: cleaned_tab_bar}} =
      Map.fetch!(Runtime.stash(current.shell_runtime), Identity.new(traditional_entry))

    cleaned_workspace = TabBar.get_workspace(cleaned_tab_bar, workspace.id)
    assert cleaned_workspace.files == []

    assert ^current = WorkspaceWorkflow.persist_changes(previous, current)
    assert %{"files" => []} = json = path |> File.read!() |> JSON.decode!()
    refute Map.has_key?(json, "active_file")

    restored_runtime =
      Runtime.activate(current.shell_runtime, traditional_entry, %TraditionalState{})

    restored_tab_bar = Runtime.state(restored_runtime).tab_bar
    restored_workspace = TabBar.get_workspace(restored_tab_bar, workspace.id)
    assert restored_workspace.files == []

    refute Enum.any?(
             restored_tab_bar.tabs,
             &match?(%Tab{payload: %TabFile{file_ref: ^file_ref}}, &1)
           )

    send(retired, :stop)
  end

  test "pure removal is not rolled back when persistence delete fails", %{tmp_dir: dir} do
    initial = TabBar.new(Tab.new_file(1, "a.ex"), dir)
    {added, workspace} = TabBar.add_workspace(initial, "Agent")
    path = Persistence.path_for(dir, workspace.id)
    File.mkdir_p!(path)

    removed = TabBar.remove_workspace(added, workspace.id)

    refute TabBar.get_workspace(removed, workspace.id)
    assert :ok = WorkspaceWorkflow.persist_tab_bar_changes(added, removed)
    assert File.dir?(path)
  end

  test "tab bar workspace mutations persist changed fields but ignore live-only fields", %{
    tmp_dir: dir
  } do
    initial = TabBar.new(Tab.new_file(1, "a.ex"), dir)
    {tab_bar, workspace} = TabBar.add_workspace(initial, "Agent")
    path = Persistence.path_for(dir, workspace.id)
    assert :ok = WorkspaceWorkflow.persist_tab_bar_changes(initial, tab_bar)
    original_json = File.read!(path)

    status_changed = TabBar.set_workspace_agent_status(tab_bar, workspace.id, :error)
    assert :ok = WorkspaceWorkflow.persist_tab_bar_changes(tab_bar, status_changed)
    assert File.read!(path) == original_json

    view_changed = TabBar.set_workspace_project_view(status_changed, workspace.id, :live_view)
    assert :ok = WorkspaceWorkflow.persist_tab_bar_changes(status_changed, view_changed)
    assert File.read!(path) == original_json

    renamed = TabBar.rename_workspace(view_changed, workspace.id, "Renamed")
    assert :ok = WorkspaceWorkflow.persist_tab_bar_changes(view_changed, renamed)

    assert {:ok, restored} = Persistence.read(path, dir)
    assert restored.label == "Renamed"
    assert %WorkspaceAgent{agent_status: :stopped, project_view: nil} = restored.payload
    assert %MingaEditor.Agent.UIState{} = restored.payload.agent_ui
  end

  test "no project root disables persistence without changing in-memory behavior" do
    workspace = Workspace.rename(Workspace.new_agent(1, "Agent"), "Memory only")

    assert workspace.label == "Memory only"
    assert :ok = Persistence.write(workspace, nil)
    assert :ok = Persistence.delete(workspace.id, nil)
    assert Persistence.scan(nil) == []
  end

  test "invalid binary project roots warn for scan and return write and delete errors", %{
    tmp_dir: dir
  } do
    invalid_root = Path.join(dir, "missing")
    workspace = Workspace.new_agent(1, "Agent", nil, invalid_root)

    scan_log = capture_log(fn -> assert Persistence.scan(invalid_root) == [] end)

    assert scan_log =~ "Could not scan workspace persistence root"
    assert scan_log =~ "invalid_project_root"

    write_log =
      capture_log(fn ->
        assert {:error, {:invalid_project_root, ^invalid_root}} =
                 Persistence.write(workspace, invalid_root)
      end)

    assert write_log =~ "Workspace persistence write failed"
    assert write_log =~ "invalid_project_root"

    delete_log =
      capture_log(fn ->
        assert {:error, {:invalid_project_root, ^invalid_root}} =
                 Persistence.delete(workspace.id, invalid_root)
      end)

    assert delete_log =~ "Workspace persistence delete failed"
    assert delete_log =~ "invalid_project_root"
  end
end
