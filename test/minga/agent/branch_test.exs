defmodule Minga.Agent.BranchTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Branch

  defp make_messages(count) do
    for i <- 1..count do
      {:user, "message #{i}"}
    end
  end

  describe "new/2" do
    test "creates a branch with name and messages" do
      msgs = make_messages(3)
      branch = Branch.new("test-branch", msgs)

      assert branch.name == "test-branch"
      assert length(branch.messages) == 3
      assert %DateTime{} = branch.created_at
    end
  end

  describe "branch_at/4" do
    test "saves current messages and truncates" do
      msgs = make_messages(5)

      {:ok, truncated, branches} = Branch.branch_at(msgs, 2, "b1", [])

      assert length(truncated) == 3
      assert length(branches) == 1
      assert hd(branches).name == "b1"
      assert length(hd(branches).messages) == 5
    end

    test "returns error for out-of-bounds index" do
      msgs = make_messages(3)
      {:error, reason} = Branch.branch_at(msgs, 10, "b1", [])
      assert reason =~ "beyond"
    end

    test "appends to existing branches" do
      msgs = make_messages(5)
      existing = [Branch.new("b0", make_messages(2))]

      {:ok, _truncated, branches} = Branch.branch_at(msgs, 1, "b1", existing)

      assert length(branches) == 2
      assert Enum.at(branches, 0).name == "b0"
      assert Enum.at(branches, 1).name == "b1"
    end
  end

  describe "list/1" do
    test "shows help when empty" do
      assert Branch.list([]) =~ "No branches"
    end

    test "shows branches with counts" do
      branches = [
        Branch.new("b1", make_messages(3)),
        Branch.new("b2", make_messages(5))
      ]

      result = Branch.list(branches)
      assert result =~ "b1"
      assert result =~ "3 messages"
      assert result =~ "b2"
      assert result =~ "5 messages"
    end
  end
end
