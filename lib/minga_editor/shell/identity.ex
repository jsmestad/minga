defmodule MingaEditor.Shell.Identity do
  @moduledoc """
  Stable registry identity for a shell registration.

  Shell ids are user-facing names that extension sources may unregister and later reuse. Runtime state and asynchronous renderer snapshots use this identity to prove they still belong to the currently registered shell before they are restored or written back.
  """

  alias MingaEditor.Shell.Entry

  @enforce_keys [:module, :source, :generation]
  defstruct [:module, :source, :generation]

  @type t :: %__MODULE__{
          module: module(),
          source: Entry.source(),
          generation: non_neg_integer()
        }

  @doc "Builds an identity from a registry entry."
  @spec new(Entry.t()) :: t()
  def new(%Entry{} = entry) do
    %__MODULE__{module: entry.module, source: entry.source, generation: entry.generation}
  end

  @doc "Returns true when the identity still refers to the registry entry."
  @spec matches?(t(), Entry.t()) :: boolean()
  def matches?(%__MODULE__{} = identity, %Entry{} = entry) do
    identity.module == entry.module and identity.source == entry.source and
      identity.generation == entry.generation
  end
end
