defmodule MingaEditor.State.Workspace.PersistenceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Project.FileRef
  alias MingaEditor.Startup
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Persistence
  alias MingaEditor.State.WorkspaceReview

  @moduletag :tmp_dir

  test "round-trips the manual workspace with files and active file", %{tmp_dir: dir} do
    {:ok, file_ref} = FileRef.from_path(dir, "lib/a.ex")

    workspace =
      dir
      |> Workspace.new_manual()
      |> Workspace.rename("Project")
      |> Workspace.set_active_file(file_ref)

    assert :ok = Persistence.write(workspace, dir)
    assert {:ok, restored} = Persistence.read(Persistence.path_for(dir, 0), dir)

    assert restored.id == 0
    assert restored.kind == :manual
    assert restored.label == "Project"
    assert restored.custom_name == "Project"
    assert restored.session == nil
    assert restored.agent_status == :stopped
    assert FileRef.equal?(restored.active_file, file_ref)
    assert Enum.any?(restored.files, &FileRef.equal?(&1, file_ref))
  end

  test "round-trips an agent workspace with custom metadata and review state", %{tmp_dir: dir} do
    {:ok, file_ref} = FileRef.from_path(dir, "lib/agent.ex")
    review = %WorkspaceReview{state: :needs_review, changed_files: [file_ref], in_progress?: true}

    workspace =
      2
      |> Workspace.new_agent("Agent", nil, dir)
      |> Workspace.rename("Investigate parser")
      |> Workspace.set_icon("sparkles")
      |> Workspace.set_active_file(file_ref)
      |> Workspace.set_review(review)

    assert :ok = Persistence.write(workspace, dir)
    assert {:ok, restored} = Persistence.read(Persistence.path_for(dir, 2), dir)

    assert restored.id == 2
    assert restored.kind == :agent
    assert restored.label == "Investigate parser"
    assert restored.custom_name == "Investigate parser"
    assert restored.icon == "sparkles"
    assert restored.session == nil
    assert restored.agent_status == :stopped
    assert restored.review.state == :needs_review
    refute restored.review.in_progress?
    assert Enum.any?(restored.review.changed_files, &FileRef.equal?(&1, file_ref))
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

  test "workspace owner mutations write persisted fields when a project root is present", %{
    tmp_dir: dir
  } do
    workspace = Workspace.new_agent(1, "Agent", nil, dir)
    path = Persistence.path_for(dir, 1)
    refute File.exists?(path)

    Workspace.rename(workspace, "Renamed")

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

    assert %Workspace{label: "Persisted Agent", session: nil, agent_status: :stopped} =
             TabBar.get_workspace(tab_bar, 3)

    assert TabBar.get_workspace(tab_bar, 0)
    assert tab_bar.next_workspace_id == 4
  end

  test "restored agent workspaces get sessionless tabs so they can be navigated", %{tmp_dir: dir} do
    workspace = Workspace.new_agent(3, "Persisted Agent", nil, dir)
    assert :ok = Persistence.write(workspace, dir)

    tab_bar = Startup.initial_tab_bar(nil, :editor, dir)
    agent_tab = Enum.find(tab_bar.tabs, &(&1.kind == :agent and &1.group_id == 3))

    assert %Tab{label: "Persisted Agent", session: nil} = agent_tab
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

  test "tab bar add and remove workspace writes and deletes persisted files", %{tmp_dir: dir} do
    tab_bar = TabBar.new(Tab.new_file(1, "a.ex"), dir)

    {tab_bar, workspace} = TabBar.add_workspace(tab_bar, "Agent")
    path = Persistence.path_for(dir, workspace.id)

    assert File.exists?(path)

    tab_bar = TabBar.remove_workspace(tab_bar, workspace.id)

    refute TabBar.get_workspace(tab_bar, workspace.id)
    refute File.exists?(path)
  end

  test "tab bar keeps workspace in memory when persisted delete fails", %{tmp_dir: dir} do
    tab_bar = TabBar.new(Tab.new_file(1, "a.ex"), dir)
    {tab_bar, workspace} = TabBar.add_workspace(tab_bar, "Agent")
    path = Persistence.path_for(dir, workspace.id)

    File.rm!(path)
    File.mkdir_p!(path)

    updated = TabBar.remove_workspace(tab_bar, workspace.id)

    assert TabBar.get_workspace(updated, workspace.id)
    assert File.dir?(path)
  end

  test "tab bar workspace mutations persist changed fields but ignore live-only fields", %{
    tmp_dir: dir
  } do
    tab_bar = TabBar.new(Tab.new_file(1, "a.ex"), dir)
    {tab_bar, workspace} = TabBar.add_workspace(tab_bar, "Agent")
    path = Persistence.path_for(dir, workspace.id)
    original_json = File.read!(path)

    tab_bar =
      TabBar.update_workspace(tab_bar, workspace.id, &Workspace.set_agent_status(&1, :error))

    assert File.read!(path) == original_json

    tab_bar =
      TabBar.update_workspace(tab_bar, workspace.id, &Workspace.set_project_view(&1, :live_view))

    assert File.read!(path) == original_json

    TabBar.update_workspace(tab_bar, workspace.id, &Workspace.rename(&1, "Renamed"))

    assert {:ok, restored} = Persistence.read(path, dir)
    assert restored.label == "Renamed"
    assert restored.agent_status == :stopped
    assert restored.project_view == nil
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
