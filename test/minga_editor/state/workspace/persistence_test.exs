defmodule MingaEditor.State.Workspace.PersistenceTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileRef
  alias MingaEditor.Startup
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

  test "no project root disables persistence without changing in-memory behavior" do
    workspace = Workspace.rename(Workspace.new_agent(1, "Agent"), "Memory only")

    assert workspace.label == "Memory only"
    assert :ok = Persistence.write(workspace, nil)
    assert Persistence.scan(nil) == []
  end
end
