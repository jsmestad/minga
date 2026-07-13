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

  @max_wire_queue 0xFFFF

  @doc "Builds a bounded FIFO policy whose queue metadata fits the wire contract."
  @spec fifo(non_neg_integer()) :: t()
  def fifo(max_queued)
      when is_integer(max_queued) and max_queued >= 0 and max_queued <= @max_wire_queue do
    %__MODULE__{mode: :fifo, max_queued: max_queued}
  end

  def fifo(max_queued) do
    raise ArgumentError,
          "FIFO max_queued must be between 0 and #{@max_wire_queue}, got: #{inspect(max_queued)}"
  end

  @doc "Builds a latest-wins policy. A superseding request cancels older work."
  @spec latest_wins() :: t()
  def latest_wins, do: %__MODULE__{mode: :latest_wins, max_queued: 0}

  @doc "Builds a bounded coalescing policy whose queue metadata fits the wire contract."
  @spec coalescing(pos_integer()) :: t()
  def coalescing(max_queued)
      when is_integer(max_queued) and max_queued > 0 and max_queued <= @max_wire_queue do
    %__MODULE__{mode: :coalescing, max_queued: max_queued}
  end

  def coalescing(max_queued) do
    raise ArgumentError,
          "coalescing max_queued must be between 1 and #{@max_wire_queue}, got: #{inspect(max_queued)}"
  end
end
