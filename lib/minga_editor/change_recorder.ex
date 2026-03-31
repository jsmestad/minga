defmodule MingaEditor.ChangeRecorder do
  @moduledoc """
  Records editing changes as raw key sequences for dot repeat.

  A pure functional module — no GenServer. The struct is embedded in
  `MingaEditor.State` and threaded through the editor's key dispatch.

  ## Recording lifecycle

  1. A change begins (insert mode entry, operator key, single-key edit) →
     `start_recording/1` clears the key buffer and sets `recording: true`.
  2. Each key event during the change → `record_key/2` appends to the buffer.
  3. The change ends (Escape back to Normal, or operator completes) →
     `stop_recording/1` copies the buffer into `last_change`.

  During replay (`replaying: true`), the editor suppresses recording so
  the replayed keys don't overwrite the stored change.
  """

  defstruct recording: false,
            keys: [],
            pending_keys: [],
            last_change: nil,
            replaying: false

  @typedoc "A key event: `{codepoint, modifiers}`."
  @type key :: {non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          recording: boolean(),
          keys: [key()],
          pending_keys: [key()],
          last_change: [key()] | nil,
          replaying: boolean()
        }

  @doc "Returns a fresh recorder with no recorded change."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Begins recording a new change. Promotes any pending keys into the recording."
  @spec start_recording(t()) :: t()
  def start_recording(%__MODULE__{pending_keys: pending} = rec) do
    %{rec | recording: true, keys: Enum.reverse(pending), pending_keys: []}
  end

  @doc "Begins recording only if not already recording. Preserves existing keys."
  @spec start_recording_if_not(t()) :: t()
  def start_recording_if_not(%__MODULE__{recording: true} = rec), do: rec
  def start_recording_if_not(%__MODULE__{} = rec), do: start_recording(rec)

  @doc "Buffers a key as a potential part of a future change (e.g., count digits, `r` prefix)."
  @spec buffer_pending_key(t(), key()) :: t()
  def buffer_pending_key(%__MODULE__{} = rec, key) do
    %{rec | pending_keys: [key | rec.pending_keys]}
  end

  @doc "Clears pending keys without saving them."
  @spec clear_pending(t()) :: t()
  def clear_pending(%__MODULE__{} = rec) do
    %{rec | pending_keys: []}
  end

  @doc """
  Appends a key to the current recording.

  No-op if not currently recording.
  """
  @spec record_key(t(), key()) :: t()
  def record_key(%__MODULE__{recording: true} = rec, key) do
    %{rec | keys: [key | rec.keys]}
  end

  def record_key(%__MODULE__{} = rec, _key), do: rec

  @doc """
  Finalizes the current recording into `last_change`.

  The key buffer is moved to `last_change` and recording stops.
  """
  @spec stop_recording(t()) :: t()
  def stop_recording(%__MODULE__{recording: true, keys: keys} = rec) do
    %{rec | recording: false, keys: [], last_change: Enum.reverse(keys)}
  end

  def stop_recording(%__MODULE__{} = rec), do: rec

  @doc """
  Cancels the current recording without saving.

  Discards the key buffer and stops recording. `last_change` is preserved.
  """
  @spec cancel_recording(t()) :: t()
  def cancel_recording(%__MODULE__{} = rec) do
    %{rec | recording: false, keys: [], pending_keys: []}
  end

  @doc "Returns the stored last-change key sequence, or `nil` if none."
  @spec get_last_change(t()) :: [key()] | nil
  def get_last_change(%__MODULE__{last_change: lc}), do: lc

  @doc "Sets the replaying flag. Recording is suppressed during replay."
  @spec start_replay(t()) :: t()
  def start_replay(%__MODULE__{} = rec), do: %{rec | replaying: true}

  @doc "Clears the replaying flag."
  @spec stop_replay(t()) :: t()
  def stop_replay(%__MODULE__{} = rec), do: %{rec | replaying: false}

  @doc "Returns `true` if currently recording a change."
  @spec recording?(t()) :: boolean()
  def recording?(%__MODULE__{recording: r}), do: r

  @doc "Returns `true` if currently replaying a change."
  @spec replaying?(t()) :: boolean()
  def replaying?(%__MODULE__{replaying: r}), do: r

  @doc """
  Replaces the count prefix in a recorded key sequence.

  Strips any leading digit keys (the original count) and prepends
  digit keys for the new count. If `new_count` is `nil` or `1`,
  returns the sequence with the original count stripped.
  """
  @spec replace_count([key()], non_neg_integer() | nil) :: [key()]
  def replace_count(keys, nil), do: keys
  def replace_count(keys, 1), do: strip_leading_digits(keys)

  def replace_count(keys, new_count) when is_integer(new_count) and new_count > 0 do
    stripped = strip_leading_digits(keys)
    digit_keys = count_to_digit_keys(new_count)
    digit_keys ++ stripped
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec strip_leading_digits([key()]) :: [key()]
  defp strip_leading_digits([{digit, 0} | rest]) when digit in ?0..?9 do
    strip_leading_digits(rest)
  end

  defp strip_leading_digits(keys), do: keys

  @spec count_to_digit_keys(pos_integer()) :: [key()]
  defp count_to_digit_keys(n) when is_integer(n) and n > 0 do
    n
    |> Integer.to_string()
    |> String.to_charlist()
    |> Enum.map(fn digit_char -> {digit_char, 0} end)
  end
end
