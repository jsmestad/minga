defmodule MingaEditor.State.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileRef
  alias MingaEditor.State.Workspace

  describe "new_manual/1" do
    test "uses the project root basename as the default label" do
      workspace = Workspace.new_manual("/tmp/minga")

      assert workspace.id == 0
      assert workspace.kind == :manual
      assert workspace.label == "minga"
      assert workspace.icon == "folder"
      assert workspace.session == nil
      assert workspace.agent_status == nil
      assert workspace.custom_name == nil
      assert workspace.files == []
      assert workspace.active_file == nil
      assert workspace.agent_ui == nil
      assert workspace.project_view == nil
      assert workspace.review.state == :clean
    end

    test "falls back to Files when no project root is recognized" do
      assert Workspace.new_manual(nil).label == "Files"
    end
  end

  describe "new_agent/3" do
    test "creates an agent workspace with correct defaults" do
      workspace = Workspace.new_agent(1, "Claude")

      assert workspace.id == 1
      assert workspace.kind == :agent
      assert workspace.label == "Claude"
      assert workspace.icon == "cpu"
      assert workspace.agent_status == :idle
      assert workspace.session == nil
      assert workspace.custom_name == nil
      assert is_integer(workspace.color)
      assert workspace.files == []
      assert workspace.active_file == nil
      assert workspace.agent_ui == nil
      assert workspace.project_view == nil
      assert workspace.review.state == :clean
    end

    test "stores session pid" do
      workspace = Workspace.new_agent(2, "Agent 2", self())
      assert workspace.session == self()
    end

    test "colors cycle through 6-color palette" do
      colors = for id <- 1..7, do: Workspace.new_agent(id, "A#{id}").color
      assert length(Enum.uniq(Enum.take(colors, 6))) == 6
      assert Enum.at(colors, 6) == Enum.at(colors, 0)
    end
  end

  describe "set_agent_status/2" do
    test "updates status" do
      workspace = Workspace.new_agent(1, "x") |> Workspace.set_agent_status(:thinking)
      assert workspace.agent_status == :thinking
    end
  end

  describe "rename/2" do
    test "sets label and stores custom_name override" do
      workspace = Workspace.new_agent(1, "Agent") |> Workspace.rename("My Research")
      assert workspace.label == "My Research"
      assert workspace.custom_name == "My Research"
    end

    test "overwrites a previous auto-named label" do
      workspace =
        Workspace.new_agent(1, "x")
        |> Workspace.auto_name("auto label")
        |> Workspace.rename("Custom")

      assert workspace.label == "Custom"
      assert workspace.custom_name == "Custom"
    end

    test "renames the manual workspace" do
      workspace = Workspace.new_manual("/tmp/minga") |> Workspace.rename("Project Files")

      assert workspace.label == "Project Files"
      assert workspace.custom_name == "Project Files"
    end
  end

  describe "set_icon/2" do
    test "changes the icon field" do
      workspace = Workspace.new_agent(1, "x") |> Workspace.set_icon("brain")
      assert workspace.icon == "brain"
    end

    test "does not affect other fields" do
      workspace = Workspace.new_agent(1, "x")
      updated = Workspace.set_icon(workspace, "star")
      assert updated.label == workspace.label
      assert updated.color == workspace.color
    end
  end

  describe "file membership" do
    test "add_file/2 stores FileRef values without duplicates" do
      {:ok, file_ref} = FileRef.from_path("/tmp/minga", "lib/user.ex")

      workspace =
        Workspace.new_manual("/tmp/minga")
        |> Workspace.add_file(file_ref)
        |> Workspace.add_file(file_ref)

      assert workspace.files == [file_ref]
    end

    test "same logical file can be a member of two workspaces" do
      {:ok, file_ref} = FileRef.from_path("/tmp/minga", "lib/user.ex")

      manual = Workspace.new_manual("/tmp/minga") |> Workspace.add_file(file_ref)
      agent = Workspace.new_agent(1, "Agent") |> Workspace.add_file(file_ref)

      assert manual.files == [file_ref]
      assert agent.files == [file_ref]
    end

    test "remove_file/2 removes matching ref and clears active file" do
      {:ok, file_ref} = FileRef.from_path("/tmp/minga", "lib/user.ex")

      workspace =
        Workspace.new_manual("/tmp/minga")
        |> Workspace.add_file(file_ref)
        |> Workspace.set_active_file(file_ref)
        |> Workspace.remove_file(file_ref)

      assert workspace.files == []
      assert workspace.active_file == nil
    end

    test "set_active_file/2 also adds missing membership" do
      {:ok, file_ref} = FileRef.from_path("/tmp/minga", "lib/user.ex")

      workspace = Workspace.new_manual("/tmp/minga") |> Workspace.set_active_file(file_ref)

      assert workspace.files == [file_ref]
      assert workspace.active_file == file_ref
      assert Workspace.has_file?(workspace, file_ref)
    end
  end

  describe "rebind_file/3" do
    test "replaces an unsaved buffer ref with a saved path ref" do
      root = Path.join(System.tmp_dir!(), "minga-workspace-rebind-buffer")
      path = Path.join([root, "lib", "user.ex"])
      File.mkdir_p!(Path.dirname(path))

      buffer =
        start_supervised!({Minga.Buffer.Process, content: "scratch", buffer_name: "*scratch*"})

      old_ref = FileRef.from_buffer(buffer)
      {:ok, new_ref} = FileRef.from_path(root, path)
      {:ok, other_ref} = FileRef.from_path(root, "lib/other.ex")

      workspace =
        Workspace.new_manual(root)
        |> Workspace.add_file(other_ref)
        |> Workspace.add_file(old_ref)
        |> Workspace.set_active_file(old_ref)
        |> Workspace.rebind_file(old_ref, new_ref)

      assert workspace.files == [other_ref, new_ref]
      assert workspace.active_file == new_ref
      refute Workspace.has_file?(workspace, old_ref)
    end

    test "replaces a saved path ref without accumulating stale membership" do
      root = Path.join(System.tmp_dir!(), "minga-workspace-rebind-path")
      old_path = Path.join([root, "lib", "user.ex"])
      new_path = Path.join([root, "lib", "user_saved.ex"])
      {:ok, old_ref} = FileRef.from_path(root, old_path)
      {:ok, new_ref} = FileRef.from_path(root, new_path)
      {:ok, other_ref} = FileRef.from_path(root, "lib/other.ex")

      workspace =
        Workspace.new_manual(root)
        |> Workspace.add_file(other_ref)
        |> Workspace.add_file(old_ref)
        |> Workspace.set_active_file(old_ref)
        |> Workspace.rebind_file(old_ref, new_ref)

      assert workspace.files == [other_ref, new_ref]
      assert workspace.active_file == new_ref
      refute Workspace.has_file?(workspace, old_ref)
    end
  end

  describe "retarget_file/4" do
    test "preserves an unrelated active file when retargeting an inactive tab" do
      root = Path.join(System.tmp_dir!(), "minga-workspace-retarget-inactive")
      {:ok, old_ref} = FileRef.from_path(root, "lib/old.ex")
      {:ok, new_ref} = FileRef.from_path(root, "lib/new.ex")
      {:ok, active_ref} = FileRef.from_path(root, "lib/active.ex")

      workspace =
        Workspace.new_manual(root)
        |> Workspace.add_file(active_ref)
        |> Workspace.add_file(old_ref)
        |> Workspace.set_active_file(active_ref)
        |> Workspace.retarget_file(old_ref, new_ref, false)

      assert workspace.files == [active_ref, new_ref]
      assert workspace.active_file == active_ref
      refute Workspace.has_file?(workspace, old_ref)
    end

    test "does not rebind an unrelated active file when the old ref is unknown" do
      root = Path.join(System.tmp_dir!(), "minga-workspace-retarget-unknown")
      {:ok, new_ref} = FileRef.from_path(root, "lib/new.ex")
      {:ok, active_ref} = FileRef.from_path(root, "lib/active.ex")

      workspace =
        Workspace.new_manual(root)
        |> Workspace.add_file(active_ref)
        |> Workspace.set_active_file(active_ref)
        |> Workspace.retarget_file(nil, new_ref, false)

      assert workspace.files == [active_ref, new_ref]
      assert workspace.active_file == active_ref
      assert Workspace.has_file?(workspace, new_ref)
    end

    test "does not steal an existing active file when the old ref is unknown" do
      root = Path.join(System.tmp_dir!(), "minga-workspace-retarget-unknown-old")
      {:ok, old_ref} = FileRef.from_path(root, "lib/old.ex")
      {:ok, new_ref} = FileRef.from_path(root, "lib/new.ex")
      {:ok, active_ref} = FileRef.from_path(root, "lib/active.ex")

      workspace =
        Workspace.new_manual(root)
        |> Workspace.add_file(active_ref)
        |> Workspace.set_active_file(active_ref)
        |> Workspace.retarget_file(old_ref, new_ref, false)

      assert workspace.files == [active_ref, new_ref]
      assert workspace.active_file == active_ref
      assert Workspace.has_file?(workspace, new_ref)
      refute Workspace.has_file?(workspace, old_ref)
    end

    test "keeps active_file nil when retargeting an inactive tab into an empty active slot" do
      root = Path.join(System.tmp_dir!(), "minga-workspace-retarget-nil-active")
      {:ok, old_ref} = FileRef.from_path(root, "lib/old.ex")
      {:ok, new_ref} = FileRef.from_path(root, "lib/new.ex")

      workspace =
        Workspace.new_manual(root)
        |> Workspace.add_file(old_ref)
        |> Workspace.retarget_file(old_ref, new_ref, false)

      assert workspace.files == [new_ref]
      assert workspace.active_file == nil
      assert Workspace.has_file?(workspace, new_ref)
      refute Workspace.has_file?(workspace, old_ref)
    end

    test "preserves active file identity when retargeting the workspace active file from an inactive tab" do
      root = Path.join(System.tmp_dir!(), "minga-workspace-retarget-active-inactive")
      {:ok, old_ref} = FileRef.from_path(root, "lib/old.ex")
      {:ok, new_ref} = FileRef.from_path(root, "lib/new.ex")

      workspace =
        Workspace.new_manual(root)
        |> Workspace.add_file(old_ref)
        |> Workspace.set_active_file(old_ref)
        |> Workspace.retarget_file(old_ref, new_ref, false)

      assert workspace.files == [new_ref]
      assert workspace.active_file == new_ref
      assert Workspace.has_file?(workspace, new_ref)
      refute Workspace.has_file?(workspace, old_ref)
    end
  end

  describe "auto_name/2" do
    test "sets label from first line of prompt" do
      workspace =
        Workspace.new_agent(1, "Agent") |> Workspace.auto_name("Fix the login bug\nMore details")

      assert workspace.label == "Fix the login bug"
    end

    test "truncates to 30 characters" do
      long = String.duplicate("a", 50)
      workspace = Workspace.new_agent(1, "x") |> Workspace.auto_name(long)
      assert String.length(workspace.label) == 30
    end

    test "skips when custom_name is set" do
      workspace =
        Workspace.new_agent(1, "x")
        |> Workspace.rename("Custom")
        |> Workspace.auto_name("ignored prompt")

      assert workspace.label == "Custom"
    end

    test "empty prompt leaves label unchanged" do
      workspace = Workspace.new_agent(1, "Agent") |> Workspace.auto_name("")
      assert workspace.label == "Agent"
    end

    test "whitespace-only prompt leaves label unchanged" do
      workspace = Workspace.new_agent(1, "Agent") |> Workspace.auto_name("   \n  \n")
      assert workspace.label == "Agent"
    end

    test "does not set custom_name" do
      workspace = Workspace.new_agent(1, "x") |> Workspace.auto_name("hello")
      assert workspace.custom_name == nil
    end
  end
end
