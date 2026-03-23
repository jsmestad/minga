defmodule Minga.Editor.State.AgentGroupTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.AgentGroup

  describe "new/3" do
    test "creates an agent group with correct defaults" do
      group = AgentGroup.new(1, "Claude")
      assert group.id == 1
      assert group.label == "Claude"
      assert group.icon == "cpu"
      assert group.agent_status == :idle
      assert group.session == nil
      assert group.custom_name == false
      assert is_integer(group.color)
    end

    test "stores session pid" do
      group = AgentGroup.new(2, "Agent 2", self())
      assert group.session == self()
    end

    test "colors cycle through 6-color palette" do
      colors = for id <- 1..7, do: AgentGroup.new(id, "A#{id}").color
      assert length(Enum.uniq(Enum.take(colors, 6))) == 6
      assert Enum.at(colors, 6) == Enum.at(colors, 0)
    end
  end

  describe "set_agent_status/2" do
    test "updates status" do
      group = AgentGroup.new(1, "x") |> AgentGroup.set_agent_status(:thinking)
      assert group.agent_status == :thinking
    end
  end

  describe "rename/2" do
    test "sets label and marks custom_name true" do
      group = AgentGroup.new(1, "Agent") |> AgentGroup.rename("My Research")
      assert group.label == "My Research"
      assert group.custom_name == true
    end

    test "overwrites a previous auto-named label" do
      group =
        AgentGroup.new(1, "x")
        |> AgentGroup.auto_name("auto label")
        |> AgentGroup.rename("Custom")

      assert group.label == "Custom"
      assert group.custom_name == true
    end
  end

  describe "set_icon/2" do
    test "changes the icon field" do
      group = AgentGroup.new(1, "x") |> AgentGroup.set_icon("brain")
      assert group.icon == "brain"
    end

    test "does not affect other fields" do
      group = AgentGroup.new(1, "x")
      updated = AgentGroup.set_icon(group, "star")
      assert updated.label == group.label
      assert updated.color == group.color
    end
  end

  describe "auto_name/2" do
    test "sets label from first line of prompt" do
      group =
        AgentGroup.new(1, "Agent") |> AgentGroup.auto_name("Fix the login bug\nMore details")

      assert group.label == "Fix the login bug"
    end

    test "truncates to 30 characters" do
      long = String.duplicate("a", 50)
      group = AgentGroup.new(1, "x") |> AgentGroup.auto_name(long)
      assert String.length(group.label) == 30
    end

    test "skips when custom_name is true" do
      group =
        AgentGroup.new(1, "x")
        |> AgentGroup.rename("Custom")
        |> AgentGroup.auto_name("ignored prompt")

      assert group.label == "Custom"
    end

    test "empty prompt leaves label unchanged" do
      group = AgentGroup.new(1, "Agent") |> AgentGroup.auto_name("")
      assert group.label == "Agent"
    end

    test "whitespace-only prompt leaves label unchanged" do
      group = AgentGroup.new(1, "Agent") |> AgentGroup.auto_name("   \n  \n")
      assert group.label == "Agent"
    end

    test "does not set custom_name flag" do
      group = AgentGroup.new(1, "x") |> AgentGroup.auto_name("hello")
      assert group.custom_name == false
    end
  end
end
