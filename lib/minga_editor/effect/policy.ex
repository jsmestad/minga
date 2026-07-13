defmodule MingaEditor.Effect.Policy do
  @moduledoc """
  Explicit bounded scheduling policy for a slow effect resource.

  `max_queued` counts waiting work, not the running worker. A value of zero
  permits only the in-flight effect.
  """

  @enforce_keys [:mode, :max_queued]
  defstruct [:mode, :max_queued]

  @type mode :: :fifo | :latest_wins | :coalescing
  @type t :: %__MODULE__{mode: mode(), max_queued: non_neg_integer()}

  @doc "Builds a bounded FIFO policy."
  @spec fifo(non_neg_integer()) :: t()
  def fifo(max_queued) when is_integer(max_queued) and max_queued >= 0 do
    %__MODULE__{mode: :fifo, max_queued: max_queued}
  end

  @doc "Builds a latest-wins policy. A superseding request cancels older work."
  @spec latest_wins() :: t()
  def latest_wins, do: %__MODULE__{mode: :latest_wins, max_queued: 0}

  @doc "Builds a bounded coalescing policy."
  @spec coalescing(pos_integer()) :: t()
  def coalescing(max_queued) when is_integer(max_queued) and max_queued > 0 do
    %__MODULE__{mode: :coalescing, max_queued: max_queued}
  end
end
