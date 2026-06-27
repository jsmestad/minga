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
          prev_count: non_neg_integer(),
          window_start: integer(),
          last_event: integer()
        }

  defstruct count: 0, prev_count: 0, window_start: 0, last_event: 0

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record(t(), integer()) :: t()
  def record(%__MODULE__{last_event: 0}, now_ms) do
    %__MODULE__{count: 1, window_start: now_ms, last_event: now_ms}
  end

  def record(%__MODULE__{} = sv, now_ms) do
    if now_ms - sv.window_start > @window_ms do
      %__MODULE__{count: 1, window_start: now_ms, last_event: now_ms, prev_count: sv.count}
    else
      %__MODULE__{sv | count: sv.count + 1, last_event: now_ms}
    end
  end

  @spec tier(t(), integer()) :: tier()
  def tier(%__MODULE__{last_event: 0}, _now_ms), do: :idle
  def tier(%__MODULE__{} = sv, now_ms) when now_ms - sv.last_event > @decay_ms, do: :idle

  def tier(%__MODULE__{count: c, prev_count: p}, _now_ms)
      when c >= @fast_threshold or p >= @fast_threshold,
      do: :fast

  def tier(%__MODULE__{count: c, prev_count: p}, _now_ms)
      when c >= @medium_threshold or p >= @medium_threshold,
      do: :medium

  def tier(%__MODULE__{}, _now_ms), do: :idle
end
