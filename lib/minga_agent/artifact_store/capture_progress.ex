defmodule MingaAgent.ArtifactStore.CaptureProgress do
  @moduledoc "Cumulative accepted capture counts without retained payload bytes."

  @type t :: %__MODULE__{bytes: non_neg_integer(), items: non_neg_integer()}

  @enforce_keys [:bytes, :items]
  defstruct [:bytes, :items]

  @doc false
  @spec new(non_neg_integer(), non_neg_integer()) :: t()
  def new(bytes, items)
      when is_integer(bytes) and bytes >= 0 and is_integer(items) and items >= 0,
      do: %__MODULE__{bytes: bytes, items: items}
end
