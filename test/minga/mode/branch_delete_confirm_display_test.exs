defmodule Minga.Mode.BranchDeleteConfirmDisplayTest do
  @moduledoc "Tests display text for branch delete confirmation prompts."
  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Mode.BranchDeleteConfirmState

  test "safe delete prompt includes branch name" do
    state = BranchDeleteConfirmState.new("/repo", "feature")

    assert Mode.display(:branch_delete_confirm, state) == "Delete branch feature? (y/n)"
  end

  test "force delete prompt includes branch name" do
    state =
      "/repo"
      |> BranchDeleteConfirmState.new("feature")
      |> BranchDeleteConfirmState.to_force("not fully merged")

    assert Mode.display(:branch_delete_confirm, state) == "Force delete branch feature? (y/n)"
  end
end
