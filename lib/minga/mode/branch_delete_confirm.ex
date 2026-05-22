defmodule Minga.Mode.BranchDeleteConfirm do
  @moduledoc """
  Git branch delete confirmation mode.

  Prompts the user before deleting a branch from the branch picker. If safe deletion reports unmerged commits, the command re-enters this mode with a force-delete prompt.
  """

  @behaviour Minga.Mode

  alias Minga.Mode
  alias Minga.Mode.BranchDeleteConfirmState

  @escape 27

  @impl Mode
  @spec handle_key(Mode.key(), BranchDeleteConfirmState.t()) :: Mode.result()

  def handle_key({?y, _mods}, %BranchDeleteConfirmState{phase: :delete} = state) do
    commands = [{:branch_delete_confirm, state.git_root, state.name, false}]
    {:execute_then_transition, commands, :normal, state}
  end

  def handle_key({?y, _mods}, %BranchDeleteConfirmState{phase: :force} = state) do
    commands = [{:branch_delete_confirm, state.git_root, state.name, true}]
    {:execute_then_transition, commands, :normal, state}
  end

  def handle_key({?n, _mods}, %BranchDeleteConfirmState{} = state) do
    {:execute_then_transition, [:branch_delete_cancel], :normal, state}
  end

  def handle_key({@escape, _mods}, %BranchDeleteConfirmState{} = state) do
    {:execute_then_transition, [:branch_delete_cancel], :normal, state}
  end

  def handle_key(_key, %BranchDeleteConfirmState{} = state) do
    {:continue, state}
  end
end
