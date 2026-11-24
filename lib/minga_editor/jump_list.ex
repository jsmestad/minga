defmodule MingaEditor.JumpList do
  @moduledoc """
  Vim's jump list: the places the cursor jumped from, across buffers.

  A jump (`G`, `gg`, a search, `%`, a mark, go to definition, a picker that opens a location) records where the cursor was before it moved. `⌃O` walks back through those places and `⌃I` walks forward again, and `SPC s j` lists them.

  The list follows Vim's rules:

  * Recording a jump appends it and forgets any older entry on the same line of the same buffer, so the list never holds two entries for one line.
  * Walking back from the newest end first records where you are, so `⌃I` can return there.
  * The list holds at most 100 entries; the oldest fall off.

  The list is a pure value. `MingaEditor.VimState` stores it, and `MingaEditor.Commands.Marks` moves the cursor.
  """

  alias Minga.Buffer

  @max_entries 100

  @typedoc "One place in the list: a buffer and a cursor position in it."
  @type entry :: {buffer :: pid(), Buffer.position()}

  @typedoc """
  The jump list.

  `entries` runs oldest first. `index` is the entry the cursor came from while walking the list; it equals the entry count when you are not walking it (the newest end).
  """
  @type t :: %__MODULE__{entries: [entry()], index: non_neg_integer()}

  defstruct entries: [], index: 0

  @doc "Returns an empty jump list."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records the place a jump started from and returns to the newest end.

  An older entry on the same line of the same buffer is forgotten first.
  """
  @spec record(t(), pid(), Buffer.position()) :: t()
  def record(%__MODULE__{entries: entries}, buffer, {line, _col} = position)
      when is_pid(buffer) do
    kept =
      entries
      |> Enum.reject(fn {entry_buffer, {entry_line, _}} ->
        entry_buffer == buffer and entry_line == line
      end)
      |> Kernel.++([{buffer, position}])
      |> Enum.take(-@max_entries)

    %__MODULE__{entries: kept, index: length(kept)}
  end

  @doc """
  Steps back one entry (`⌃O`) from the current place.

  At the newest end the current place is recorded first, so stepping forward returns to it. Returns `:none` when there is no older entry.
  """
  @spec back(t(), pid(), Buffer.position()) :: {:ok, entry(), t()} | :none
  def back(%__MODULE__{entries: entries, index: index} = list, buffer, position) do
    if index >= length(entries) do
      recorded = record(list, buffer, position)
      step_to(recorded, recorded.index - 2)
    else
      step_to(list, index - 1)
    end
  end

  @doc "Steps forward one entry (`⌃I`). Returns `:none` at the newest entry."
  @spec forward(t()) :: {:ok, entry(), t()} | :none
  def forward(%__MODULE__{index: index} = list), do: step_to(list, index + 1)

  @doc """
  Moves the walk position to one entry by its index, as picking a row in the jump list does.

  Returns `:none` for an index outside the list.
  """
  @spec go_to(t(), non_neg_integer()) :: {:ok, entry(), t()} | :none
  def go_to(%__MODULE__{} = list, index) when is_integer(index), do: step_to(list, index)

  @doc """
  Forgets every entry in a buffer, for example after the buffer closed.

  The walk position stays on the same entry when it is kept. When it is forgotten, the position moves to the first kept entry after it, so a walk can continue from where the forgotten entry was.
  """
  @spec forget_buffer(t(), pid()) :: t()
  def forget_buffer(%__MODULE__{entries: entries, index: index}, buffer) do
    {before, after_index} = Enum.split(entries, index)
    kept_before = Enum.reject(before, &match?({^buffer, _}, &1))
    kept_after = Enum.reject(after_index, &match?({^buffer, _}, &1))
    %__MODULE__{entries: kept_before ++ kept_after, index: length(kept_before)}
  end

  @doc "Returns the entries, oldest first, with the index the walk is at."
  @spec entries(t()) :: {[entry()], non_neg_integer()}
  def entries(%__MODULE__{entries: entries, index: index}), do: {entries, index}

  @spec step_to(t(), integer()) :: {:ok, entry(), t()} | :none
  defp step_to(_list, target) when target < 0, do: :none

  defp step_to(%__MODULE__{entries: entries} = list, target) do
    case Enum.fetch(entries, target) do
      {:ok, entry} -> {:ok, entry, %{list | index: target}}
      :error -> :none
    end
  end
end
