defmodule MingaEditor.Shell.Identity do
  @moduledoc """
  Exact identity for one shell registration.

  Shell ids are user-facing names that extension sources may unregister and later reuse. Runtime state, stashes, and asynchronous renderer snapshots compare the same id, module, source, and registry generation before state is restored or written back.
  """

  alias MingaEditor.Shell.Entry

  @enforce_keys [:id, :module, :source, :generation]
  defstruct [:id, :module, :source, :generation]

  @type t :: %__MODULE__{
          id: atom(),
          module: module(),
          source: Entry.source(),
          generation: non_neg_integer()
        }

  @type comparable :: t() | Entry.t()

  @doc "Builds an exact identity from a registry entry."
  @spec new(Entry.t()) :: t()
  def new(%Entry{} = entry) do
    %__MODULE__{
      id: entry.id,
      module: entry.module,
      source: entry.source,
      generation: entry.generation
    }
  end

  @doc "Returns true when two values describe the same exact registration."
  @spec matches?(comparable(), comparable()) :: boolean()
  def matches?(left, right), do: normalize(left) == normalize(right)

  @spec normalize(comparable()) :: t()
  defp normalize(%__MODULE__{} = identity), do: identity
  defp normalize(%Entry{} = entry), do: new(entry)
end
