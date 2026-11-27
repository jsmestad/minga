defmodule Minga.Mode.DeleteConfirmState do
  @moduledoc """
  FSM state for the file tree delete confirmation prompt.

  Holds the path and entry kind without reading the filesystem. Also tracks
  whether this is the initial trash prompt or the permanent-delete fallback.
  """

  @enforce_keys [:path, :name, :dir?, :identity]
  defstruct [
    :path,
    :name,
    :dir?,
    :identity,
    phase: :trash,
    count: nil
  ]

  @type phase :: :trash | :permanent

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          dir?: boolean(),
          identity: Minga.Core.FileIdentity.t(),
          phase: phase(),
          count: non_neg_integer() | nil
        }

  @doc "Creates a new delete confirm state for the given file tree entry."
  @spec new(String.t(), String.t(), boolean(), Minga.Core.FileIdentity.t()) :: t()
  def new(path, name, dir?, identity) do
    %__MODULE__{
      path: path,
      name: name,
      dir?: dir?,
      identity: identity
    }
  end

  @doc "Offers permanent deletion only for the entry the trash attempt saw."
  @spec to_permanent(t()) :: t()
  def to_permanent(%__MODULE__{phase: :trash} = state) do
    %{state | phase: :permanent}
  end
end
