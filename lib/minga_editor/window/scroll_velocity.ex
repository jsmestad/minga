defmodule MingaEditor.Window.ScrollVelocity do
  @moduledoc """
  Lightweight scroll velocity estimator for adaptive overscan.

  Tracks a sliding window of scroll event timestamps and computes a
  velocity tier (:idle, :medium, :fast) based on event rate. The tier
  is read lazily by BufferPrefetch to scale overscan rows.
  """

  @window_ms 100
  @decay_ms 200
  @medium_threshold 5
  @fast_threshold 15

  @type tier :: :idle | :medium | :fast

  @type t :: %__MODULE__{
          count: non_neg_integer(),
          window_start: integer(),
          last_event: integer()
        }

  defstruct count: 0, window_start: 0, last_event: 0

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record(t(), integer()) :: t()
  def record(%__MODULE__{} = sv, now_ms) do
    if now_ms - sv.window_start > @window_ms do
      %__MODULE__{count: 1, window_start: now_ms, last_event: now_ms}
    else
      %__MODULE__{sv | count: sv.count + 1, last_event: now_ms}
    end
  end

  @spec tier(t(), integer()) :: tier()
  def tier(%__MODULE__{last_event: 0}, _now_ms), do: :idle

  def tier(%__MODULE__{} = sv, now_ms) do
    if now_ms - sv.last_event > @decay_ms do
      :idle
    else
      cond do
        sv.count >= @fast_threshold -> :fast
        sv.count >= @medium_threshold -> :medium
        true -> :idle
      end
    end
  end
end
