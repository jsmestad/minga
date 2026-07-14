defmodule MingaEditor.Shell.StateStash do
  @moduledoc """
  Stashed shell state tied to the exact shell registration that produced it.

  Shell state is safe to restore only into the same registered shell id, module, source, and generation. `MingaEditor.Shell.Identity` owns that comparison contract for registration, runtime, renderer, and stash paths.
  """

  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Identity

  @enforce_keys [:identity, :state]
  defstruct [:identity, :state]

  @type t :: %__MODULE__{
          identity: Identity.t(),
          state: MingaEditor.Shell.shell_state()
        }

  @doc "Stores shell state with the exact registry identity that produced it."
  @spec new(Entry.t(), MingaEditor.Shell.shell_state()) :: t()
  def new(%Entry{} = entry, state) do
    %__MODULE__{identity: Identity.new(entry), state: state}
  end

  @doc "Returns true when the stash belongs to the current exact registry entry."
  @spec matches?(t(), Entry.t()) :: boolean()
  def matches?(%__MODULE__{} = stash, %Entry{} = entry) do
    Identity.matches?(stash.identity, entry)
  end

  @doc "Restores stored state only when the current registry entry has the same exact identity."
  @spec restore(t(), Entry.t()) :: {:ok, MingaEditor.Shell.shell_state()} | :mismatch
  def restore(%__MODULE__{} = stash, %Entry{} = entry) do
    if matches?(stash, entry), do: {:ok, stash.state}, else: :mismatch
  end
end
