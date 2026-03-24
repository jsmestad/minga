defmodule Minga.Editor.State.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Workspace

  describe "manual/0" do
    test "creates the default workspace with id 0" do
      ws = Workspace.manual()
      assert ws.id == 0
      assert ws.kind == :manual
      # Label is the project directory name or "Files" fallback
      assert is_binary(ws.label)
      assert ws.label != ""
      assert ws.color == 0x51AFEF
      assert ws.session == nil
      assert ws.agent_status == nil
    end
  end

  describe "new_agent/3" do
    test "creates an agent workspace with auto-assigned color" do
      ws = Workspace.new_agent(1, "Claude")
      assert ws.id == 1
      assert ws.kind == :agent
      assert ws.label == "Claude"
      assert ws.agent_status == :idle
      assert ws.session == nil
      assert is_integer(ws.color)
    end

    test "stores session pid" do
      ws = Workspace.new_agent(2, "Agent 2", self())
      assert ws.session == self()
    end

    test "agent colors cycle through 6-color palette" do
      colors = for id <- 1..7, do: Workspace.new_agent(id, "A#{id}").color
      # First 6 should all be distinct
      assert length(Enum.uniq(Enum.take(colors, 6))) == 6
      # 7th wraps to same as 1st
      assert Enum.at(colors, 6) == Enum.at(colors, 0)
    end
  end

  describe "manual?/1 and agent?/1" do
    test "are mutually exclusive" do
      manual = Workspace.manual()
      assert Workspace.manual?(manual)
      refute Workspace.agent?(manual)

      agent = Workspace.new_agent(1, "x")
      assert Workspace.agent?(agent)
      refute Workspace.manual?(agent)
    end
  end

  describe "set_agent_status/2" do
    test "updates status" do
      ws = Workspace.new_agent(1, "x") |> Workspace.set_agent_status(:thinking)
      assert ws.agent_status == :thinking
    end
  end

  describe "rename/2" do
    test "sets label and marks custom_name true" do
      ws = Workspace.new_agent(1, "Agent") |> Workspace.rename("My Research")
      assert ws.label == "My Research"
      assert ws.custom_name == true
    end

    test "overwrites a previous auto-named label" do
      ws =
        Workspace.new_agent(1, "x")
        |> Workspace.auto_name("auto label")
        |> Workspace.rename("Custom")

      assert ws.label == "Custom"
      assert ws.custom_name == true
    end
  end

  describe "set_icon/2" do
    test "changes the icon field" do
      ws = Workspace.new_agent(1, "x") |> Workspace.set_icon("brain")
      assert ws.icon == "brain"
    end

    test "does not affect other fields" do
      ws = Workspace.new_agent(1, "x")
      updated = Workspace.set_icon(ws, "star")
      assert updated.label == ws.label
      assert updated.color == ws.color
    end
  end

  describe "auto_name/2" do
    test "sets label from first line of prompt" do
      ws =
        Workspace.new_agent(1, "Agent") |> Workspace.auto_name("Fix the login bug\nMore details")

      assert ws.label == "Fix the login bug"
    end

    test "truncates to 30 characters" do
      long = String.duplicate("a", 50)
      ws = Workspace.new_agent(1, "x") |> Workspace.auto_name(long)
      assert String.length(ws.label) == 30
    end

    test "skips when custom_name is true" do
      ws =
        Workspace.new_agent(1, "x")
        |> Workspace.rename("Custom")
        |> Workspace.auto_name("ignored prompt")

      assert ws.label == "Custom"
    end

    test "empty prompt leaves label unchanged" do
      ws = Workspace.new_agent(1, "Agent") |> Workspace.auto_name("")
      assert ws.label == "Agent"
    end

    test "whitespace-only prompt leaves label unchanged" do
      ws = Workspace.new_agent(1, "Agent") |> Workspace.auto_name("   \n  \n")
      assert ws.label == "Agent"
    end

    test "does not set custom_name flag" do
      ws = Workspace.new_agent(1, "x") |> Workspace.auto_name("hello")
      assert ws.custom_name == false
    end
  end
end
