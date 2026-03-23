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
end
