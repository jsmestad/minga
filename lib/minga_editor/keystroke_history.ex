defmodule MingaEditor.KeystrokeHistory do
  @moduledoc """
  Bounded ring buffer of recent keystrokes for the lossage display (`SPC h l`).

  A pure functional module, no GenServer. The struct lives on
  `MingaEditor.State` (global, not per-tab) and is updated on every
  key press in `Input.Router.dispatch_normal/3`.

  Entries are stored newest-first internally and returned in
  chronological order by `entries/1`.
  """

  @default_max_size 200

  defstruct entries: [],
            count: 0,
            max_size: @default_max_size

  @typedoc "A single recorded keystroke."
  @type entry :: %{
          key: {non_neg_integer(), non_neg_integer()},
          mode_before: atom(),
          mode_after: atom(),
          timestamp: integer()
        }

  @type t :: %__MODULE__{
          entries: [entry()],
          count: non_neg_integer(),
          max_size: pos_integer()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(pos_integer()) :: t()
  def new(max_size) when is_integer(max_size) and max_size > 0 do
    %__MODULE__{max_size: max_size}
  end

  @spec record(t(), entry()) :: t()
  def record(%__MODULE__{entries: entries, count: count, max_size: max_size} = history, entry) do
    new_entries = [entry | entries]
    new_count = count + 1

    if new_count > max_size do
      %{history | entries: Enum.take(new_entries, max_size), count: max_size}
    else
      %{history | entries: new_entries, count: new_count}
    end
  end

  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{entries: entries}), do: Enum.reverse(entries)

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{count: count}), do: count
end
