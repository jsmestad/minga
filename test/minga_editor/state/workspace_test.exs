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
      assert workspace.review == nil
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
      assert workspace.review == nil
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
