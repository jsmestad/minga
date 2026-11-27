defmodule Minga.Mode.DeleteConfirmState do
  @moduledoc """
  FSM state for the file tree delete confirmation prompt.

  Holds the path and entry kind without reading the filesystem. Also tracks
  whether this is the initial trash prompt or the permanent-delete fallback.
  """

  @enforce_keys [:path, :name, :dir?]
  defstruct [
    :path,
    :name,
    :dir?,
    phase: :trash,
    count: nil
  ]

  @type phase :: :trash | :permanent

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          dir?: boolean(),
          phase: phase(),
          count: non_neg_integer() | nil
        }

  @doc "Creates a new delete confirm state for the given file tree entry."
  @spec new(String.t(), String.t(), boolean()) :: t()
  def new(path, name, dir?) do
    %__MODULE__{
      path: path,
      name: name,
      dir?: dir?
    }
  end

  @doc "Transitions to the permanent delete fallback prompt."
  @spec to_permanent(t()) :: t()
  def to_permanent(%__MODULE__{} = state) do
    %{state | phase: :permanent}
  end
end
