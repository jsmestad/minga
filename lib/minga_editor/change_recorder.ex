defmodule MingaEditor.ChangeRecorder do
  @moduledoc """
  Records editing changes as raw key sequences for dot repeat.

  The `phase` carries exactly one active lifecycle, while replay can preserve a post-replay recording phase that is restored after the outermost replay returns normally.
  """

  defstruct phase: :idle,
            pending_keys: [],
            last_change: nil

  @type key :: {non_neg_integer(), non_neg_integer()}

  @type post_phase :: :idle | {:recording, [key()]}
  @type phase :: :idle | {:recording, [key()]} | {:replaying, pos_integer(), post_phase()}

  @type t :: %__MODULE__{
          phase: phase(),
          pending_keys: [key()],
          last_change: [key()] | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec start_recording(t()) :: t()
  def start_recording(%__MODULE__{phase: {:replaying, depth, _post}, pending_keys: pending} = rec) do
    %{rec | phase: {:replaying, depth, {:recording, Enum.reverse(pending)}}, pending_keys: []}
  end

  def start_recording(%__MODULE__{pending_keys: pending} = rec) do
    %{rec | phase: {:recording, Enum.reverse(pending)}, pending_keys: []}
  end

  @spec start_recording_if_not(t()) :: t()
  def start_recording_if_not(%__MODULE__{phase: {:recording, _keys}} = rec), do: rec

  def start_recording_if_not(%__MODULE__{phase: {:replaying, _depth, {:recording, _keys}}} = rec),
    do: rec

  def start_recording_if_not(%__MODULE__{} = rec), do: start_recording(rec)

  @spec buffer_pending_key(t(), key()) :: t()
  def buffer_pending_key(%__MODULE__{} = rec, key) do
    %{rec | pending_keys: [key | rec.pending_keys]}
  end

  @spec clear_pending(t()) :: t()
  def clear_pending(%__MODULE__{} = rec) do
    %{rec | pending_keys: []}
  end

  @spec record_key(t(), key()) :: t()
  def record_key(%__MODULE__{phase: {:recording, keys}} = rec, key) do
    %{rec | phase: {:recording, [key | keys]}}
  end

  def record_key(%__MODULE__{} = rec, _key), do: rec

  @spec stop_recording(t()) :: t()
  def stop_recording(%__MODULE__{phase: {:recording, keys}} = rec) do
    %{rec | phase: :idle, last_change: Enum.reverse(keys)}
  end

  def stop_recording(%__MODULE__{phase: {:replaying, depth, {:recording, keys}}} = rec) do
    %{rec | phase: {:replaying, depth, :idle}, last_change: Enum.reverse(keys)}
  end

  def stop_recording(%__MODULE__{} = rec), do: rec

  @spec cancel_recording(t()) :: t()
  def cancel_recording(%__MODULE__{phase: {:replaying, depth, _post}} = rec) do
    %{rec | phase: {:replaying, depth, :idle}, pending_keys: []}
  end

  def cancel_recording(%__MODULE__{} = rec) do
    %{rec | phase: :idle, pending_keys: []}
  end

  @spec get_last_change(t()) :: [key()] | nil
  def get_last_change(%__MODULE__{last_change: lc}), do: lc

  @spec start_replay(t()) :: t()
  def start_replay(%__MODULE__{phase: {:replaying, depth, post}} = rec) do
    %{rec | phase: {:replaying, depth + 1, post}}
  end

  def start_replay(%__MODULE__{phase: phase} = rec) do
    %{rec | phase: {:replaying, 1, phase}}
  end

  @spec stop_replay(t()) :: t()
  def stop_replay(%__MODULE__{phase: {:replaying, depth, post}} = rec) when depth > 1 do
    %{rec | phase: {:replaying, depth - 1, post}}
  end

  def stop_replay(%__MODULE__{phase: {:replaying, 1, post}} = rec) do
    %{rec | phase: post}
  end

  def stop_replay(%__MODULE__{} = rec), do: rec

  @spec recording?(t()) :: boolean()
  def recording?(%__MODULE__{phase: {:recording, _keys}}), do: true
  def recording?(%__MODULE__{phase: {:replaying, _depth, {:recording, _keys}}}), do: true
  def recording?(%__MODULE__{}), do: false

  @spec replaying?(t()) :: boolean()
  def replaying?(%__MODULE__{phase: {:replaying, _depth, _post}}), do: true
  def replaying?(%__MODULE__{}), do: false

  @spec replace_count([key()], non_neg_integer() | nil) :: [key()]
  def replace_count(keys, nil), do: keys
  def replace_count(keys, 1), do: strip_leading_digits(keys)

  def replace_count(keys, new_count) when is_integer(new_count) and new_count > 0 do
    stripped = strip_leading_digits(keys)
    digit_keys = count_to_digit_keys(new_count)
    digit_keys ++ stripped
  end

  defp strip_leading_digits([{digit, 0} | rest]) when digit in ?0..?9 do
    strip_leading_digits(rest)
  end

  defp strip_leading_digits(keys), do: keys

  defp count_to_digit_keys(n) when is_integer(n) and n > 0 do
    n
    |> Integer.to_string()
    |> String.to_charlist()
    |> Enum.map(fn digit_char -> {digit_char, 0} end)
  end
end
