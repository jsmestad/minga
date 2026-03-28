defmodule Minga.Mode.DeleteConfirmState do
  @moduledoc """
  FSM state for the file tree delete confirmation prompt.

  Holds the path being deleted, whether it's a directory, and the child
  count (for directory prompts). Also tracks whether this is the initial
  trash prompt or the permanent-delete fallback prompt.
  """

  @enforce_keys [:path, :name, :dir?]
  defstruct [
    :path,
    :name,
    :dir?,
    child_count: 0,
    phase: :trash,
    count: nil
  ]

  @type phase :: :trash | :permanent

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          dir?: boolean(),
          child_count: non_neg_integer(),
          phase: phase(),
          count: non_neg_integer() | nil
        }

  @doc "Creates a new delete confirm state for the given file tree entry."
  @spec new(String.t(), String.t(), boolean(), non_neg_integer()) :: t()
  def new(path, name, dir?, child_count \\ 0) do
    %__MODULE__{
      path: path,
      name: name,
      dir?: dir?,
      child_count: child_count
    }
  end

  @doc "Transitions to the permanent delete fallback prompt."
  @spec to_permanent(t()) :: t()
  def to_permanent(%__MODULE__{} = state) do
    %{state | phase: :permanent}
  end
end
