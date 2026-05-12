defmodule MingaEditor.KeystrokeHistory do
  @moduledoc """
  Bounded list of the most recent keystrokes for the lossage display (`SPC h l`).

  A pure functional module, no GenServer. The struct lives on
  `MingaEditor.State` (global, not per-tab) and is updated once per
  key event, after dispatch but before post-key housekeeping.

  Entries are stored newest-first internally and returned in
  chronological order by `entries/1`.
  """

  @default_max_size 200

  defmodule Entry do
    @moduledoc false

    @enforce_keys [:key, :mode_before, :mode_after, :timestamp]
    defstruct [:key, :mode_before, :mode_after, :timestamp]

    @type t :: %__MODULE__{
            key: {non_neg_integer(), non_neg_integer()},
            mode_before: Minga.Mode.mode(),
            mode_after: Minga.Mode.mode(),
            timestamp: non_neg_integer()
          }
  end

  defstruct entries: [],
            max_size: @default_max_size

  @type entry :: Entry.t()

  @type t :: %__MODULE__{
          entries: [entry()],
          max_size: pos_integer()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(pos_integer()) :: t()
  def new(max_size) when is_integer(max_size) and max_size > 0 do
    %__MODULE__{max_size: max_size}
  end

  @spec record(t(), entry()) :: t()
  def record(%__MODULE__{entries: entries, max_size: max_size} = history, %Entry{} = entry) do
    new_entries = [entry | entries]

    if length(new_entries) > max_size do
      %{history | entries: Enum.take(new_entries, max_size)}
    else
      %{history | entries: new_entries}
    end
  end

  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{entries: entries}), do: Enum.reverse(entries)

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: length(entries)
end
