defmodule Minga.Buffer.ChangeLog do
  @moduledoc """
  Ordered record of edit deltas that lets sync consumers catch up independently.

  The buffer process applies edits to the document immediately. This struct remembers the resulting `Minga.Buffer.EditDelta` values for systems that sync incrementally, such as highlighting or language tooling. Each consumer keeps its own cursor, so one consumer reading changes does not steal them from another consumer.

  This module is pure state. It does not broadcast events, adjust decorations, or know about GenServer calls.
  """

  alias Minga.Buffer.EditDelta

  @max_single_consumer_entries 1000

  @type consumer :: atom()
  @type sequence :: non_neg_integer()
  @type entry :: {sequence(), EditDelta.t()}
  @type unseen_changes :: {:ok, [EditDelta.t()]} | :reset_required

  defstruct pending_changes: [],
            sequence: 0,
            entries: [],
            consumer_cursors: %{}

  @opaque t :: %__MODULE__{
            pending_changes: [EditDelta.t()],
            sequence: sequence(),
            entries: [entry()],
            consumer_cursors: %{consumer() => sequence()}
          }

  @doc "Creates an empty change log."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Records a new edit delta."
  @spec record_change(t(), EditDelta.t()) :: t()
  def record_change(%__MODULE__{} = log, %EditDelta{} = delta) do
    sequence = log.sequence + 1

    %{
      log
      | pending_changes: [delta | log.pending_changes],
        sequence: sequence,
        entries: [{sequence, delta} | log.entries]
    }
  end

  @doc "Returns globally pending changes in edit order and clears that legacy pending list."
  @spec drain_pending_changes(t()) :: {[EditDelta.t()], t()}
  def drain_pending_changes(%__MODULE__{} = log) do
    {Enum.reverse(log.pending_changes), %{log | pending_changes: []}}
  end

  @doc """
  Returns changes unseen by `consumer` in edit order and advances that consumer's cursor.

  Returns `:reset_required` when older retained entries were compacted before the consumer caught up. Callers must full-sync their downstream state in that case.
  """
  @spec take_unseen_changes(t(), consumer()) :: {unseen_changes(), t()}
  def take_unseen_changes(%__MODULE__{} = log, consumer) when is_atom(consumer) do
    cursor = Map.get(log.consumer_cursors, consumer, 0)
    result = unseen_changes(log, cursor)
    consumer_cursors = Map.put(log.consumer_cursors, consumer, log.sequence)
    log = %{log | consumer_cursors: consumer_cursors}

    {result, compact(log)}
  end

  @doc "Clears all recorded changes and consumer cursors."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = log) do
    %{log | pending_changes: [], entries: [], consumer_cursors: %{}}
  end

  @doc false
  @spec retained_count(t()) :: non_neg_integer()
  def retained_count(%__MODULE__{} = log), do: length(log.entries)

  @spec unseen_changes(t(), sequence()) :: unseen_changes()
  defp unseen_changes(%__MODULE__{sequence: sequence}, cursor) when cursor >= sequence,
    do: {:ok, []}

  defp unseen_changes(%__MODULE__{entries: []}, _cursor), do: :reset_required

  defp unseen_changes(%__MODULE__{} = log, cursor) do
    earliest = earliest_retained_sequence(log.entries)

    if cursor + 1 < earliest do
      :reset_required
    else
      {:ok, changes_after(log.entries, cursor)}
    end
  end

  @spec changes_after([entry()], sequence()) :: [EditDelta.t()]
  defp changes_after(entries, cursor) do
    entries
    |> Enum.filter(fn {sequence, _delta} -> sequence > cursor end)
    |> Enum.sort_by(fn {sequence, _delta} -> sequence end)
    |> Enum.map(fn {_sequence, delta} -> delta end)
  end

  @spec earliest_retained_sequence([entry()]) :: sequence()
  defp earliest_retained_sequence(entries) do
    entries
    |> Enum.map(fn {sequence, _delta} -> sequence end)
    |> Enum.min()
  end

  @spec compact(t()) :: t()
  defp compact(%__MODULE__{consumer_cursors: cursors} = log) when map_size(cursors) >= 2 do
    min_cursor = cursors |> Map.values() |> Enum.min()
    %{log | entries: Enum.filter(log.entries, fn {sequence, _delta} -> sequence > min_cursor end)}
  end

  defp compact(%__MODULE__{} = log) do
    %{log | entries: Enum.take(log.entries, @max_single_consumer_entries)}
  end
end
