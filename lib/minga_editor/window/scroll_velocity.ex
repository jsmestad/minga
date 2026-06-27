defmodule MingaEditor.Window.ScrollVelocity do
  @moduledoc """
  Lightweight scroll velocity estimator for adaptive overscan.

  Tracks a sliding window of scroll event timestamps and computes a
  velocity tier (:idle, :medium, :fast) based on event rate, plus
  a dominant scroll direction (:down, :up, :ambiguous) from the last
  several events. Both are read lazily by BufferPrefetch to scale and
  bias overscan rows.
  """

  @window_ms 100
  @decay_ms 200
  @medium_threshold 5
  @fast_threshold 15
  @direction_window 5

  @type tier :: :idle | :medium | :fast
  @type event_direction :: :down | :up
  @type direction :: event_direction() | :ambiguous

  @type t :: %__MODULE__{
          count: non_neg_integer(),
          prev_count: non_neg_integer(),
          window_start: integer(),
          last_event: integer(),
          recent_dirs: [event_direction()]
        }

  defstruct count: 0, prev_count: 0, window_start: 0, last_event: 0, recent_dirs: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record(t(), integer(), event_direction()) :: t()
  def record(%__MODULE__{last_event: 0}, now_ms, dir) do
    %__MODULE__{count: 1, window_start: now_ms, last_event: now_ms, recent_dirs: [dir]}
  end

  def record(%__MODULE__{} = sv, now_ms, dir) do
    dirs = Enum.take([dir | sv.recent_dirs], @direction_window)

    if now_ms - sv.window_start > @window_ms do
      %__MODULE__{
        count: 1,
        window_start: now_ms,
        last_event: now_ms,
        prev_count: sv.count,
        recent_dirs: dirs
      }
    else
      %__MODULE__{sv | count: sv.count + 1, last_event: now_ms, recent_dirs: dirs}
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

  @spec direction(t(), integer()) :: direction()
  def direction(%__MODULE__{last_event: 0}, _now_ms), do: :ambiguous

  def direction(%__MODULE__{} = sv, now_ms) when now_ms - sv.last_event > @decay_ms,
    do: :ambiguous

  def direction(%__MODULE__{recent_dirs: dirs}, _now_ms) do
    downs = Enum.count(dirs, &(&1 == :down))
    ups = Enum.count(dirs, &(&1 == :up))
    total = length(dirs)

    cond do
      downs * 5 >= total * 4 -> :down
      ups * 5 >= total * 4 -> :up
      true -> :ambiguous
    end
  end
end
