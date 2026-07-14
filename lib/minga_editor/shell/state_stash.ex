defmodule MingaEditor.Shell.StateStash do
  @moduledoc """
  Stashed shell state tied to the exact shell registry identity that produced it.

  Shell state is only safe to restore into the same registered shell id, module, and source. Extension shell ids can be unregistered and later reused, so the registry generation is part of the identity as well.
  """

  alias MingaEditor.Shell.Entry

  @enforce_keys [:id, :module, :source, :generation, :state]
  defstruct [:id, :module, :source, :generation, :state]

  @type t :: %__MODULE__{
          id: atom(),
          module: module(),
          source: Entry.source(),
          generation: non_neg_integer(),
          state: MingaEditor.Shell.shell_state()
        }

  @doc "Stores shell state with the registry identity that produced it."
  @spec new(Entry.t(), MingaEditor.Shell.shell_state()) :: t()
  def new(%Entry{} = entry, state) do
    %__MODULE__{
      id: entry.id,
      module: entry.module,
      source: entry.source,
      generation: entry.generation,
      state: state
    }
  end

  @doc "Returns true when the stash belongs to the current registry entry."
  @spec matches?(t(), Entry.t()) :: boolean()
  def matches?(%__MODULE__{} = stash, %Entry{} = entry) do
    stash.id == entry.id and stash.module == entry.module and stash.source == entry.source and
      stash.generation == entry.generation
  end

  @doc "Restores stored state only when the current registry entry has the same identity."
  @spec restore(t(), Entry.t()) :: {:ok, MingaEditor.Shell.shell_state()} | :mismatch
  def restore(%__MODULE__{} = stash, %Entry{} = entry) do
    if matches?(stash, entry), do: {:ok, stash.state}, else: :mismatch
  end
end
