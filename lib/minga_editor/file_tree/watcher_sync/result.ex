defmodule MingaEditor.FileTree.WatcherSync.Result do
  @moduledoc "Typed immutable result of one successful watcher synchronization."

  @enforce_keys [:target]
  defstruct [:target]

  @type t :: %__MODULE__{target: String.t() | nil}

  @doc "Builds a result for the exact synchronized target."
  @spec new(String.t() | nil) :: t()
  def new(nil), do: %__MODULE__{target: nil}
  def new(target) when is_binary(target), do: %__MODULE__{target: Path.expand(target)}
end
