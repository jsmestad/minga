defmodule Minga.Mode.BranchDeleteConfirmState do
  @moduledoc """
  FSM state for confirming git branch deletion.

  Holds the git root, branch name, and whether the prompt is the initial safe delete or the force-delete fallback after git reports unmerged commits.
  """

  @enforce_keys [:git_root, :name]
  defstruct [:git_root, :name, phase: :delete, reason: nil, count: nil]

  @type phase :: :delete | :force

  @type t :: %__MODULE__{
          git_root: String.t(),
          name: String.t(),
          phase: phase(),
          reason: String.t() | nil,
          count: non_neg_integer() | nil
        }

  @doc "Creates a new branch delete confirmation state."
  @spec new(String.t(), String.t()) :: t()
  def new(git_root, name) when is_binary(git_root) and is_binary(name) do
    %__MODULE__{git_root: git_root, name: name}
  end

  @doc "Transitions to the force-delete confirmation prompt."
  @spec to_force(t(), String.t()) :: t()
  def to_force(%__MODULE__{} = state, reason) when is_binary(reason) do
    %{state | phase: :force, reason: reason}
  end
end
