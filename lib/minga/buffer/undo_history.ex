defmodule Minga.Buffer.UndoHistory do
  @moduledoc """
  Undo and redo history for a buffer document.

  The buffer process owns the live document and version counter. This struct remembers the snapshots needed to move backward and forward through document history, including the source of each edit for diagnostics and attribution.

  This module is pure state. It does not mark buffers dirty, broadcast events, or mutate documents.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.UndoHistory.Restore

  @max_entries 1000
  @coalesce_ms 300

  @type edit_source :: EditSource.undo_source()
  @type version :: non_neg_integer()
  @type entry :: {version(), Document.t(), edit_source()}

  defstruct undo_entries: [],
            redo_entries: [],
            last_recorded_at: 0

  @opaque t :: %__MODULE__{
            undo_entries: [entry()],
            redo_entries: [entry()],
            last_recorded_at: integer()
          }

  @doc "Creates an empty undo history."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the coalescing window in milliseconds."
  @spec coalesce_ms() :: pos_integer()
  def coalesce_ms, do: @coalesce_ms

  @doc "Records an undo snapshot, coalescing rapid edits into one history entry."
  @spec record_edit(t(), version(), Document.t(), edit_source()) :: t()
  def record_edit(%__MODULE__{} = history, version, %Document{} = document, source)
      when source in [:user, :agent, :lsp, :recovery] do
    now = System.monotonic_time(:millisecond)
    elapsed = now - history.last_recorded_at

    do_record_edit(history, version, document, source, now, elapsed)
  end

  @doc "Records an undo snapshot without time-based coalescing."
  @spec record_edit_force(t(), version(), Document.t(), edit_source()) :: t()
  def record_edit_force(%__MODULE__{} = history, version, %Document{} = document, source)
      when source in [:user, :agent, :lsp, :recovery] do
    now = System.monotonic_time(:millisecond)
    entry = {version, document, source}

    %{
      history
      | undo_entries: cap_entries([entry | history.undo_entries]),
        redo_entries: [],
        last_recorded_at: now
    }
  end

  @doc "Returns the previous document/version and updates history, or `:empty` when undo is unavailable."
  @spec undo(t(), version(), Document.t()) :: {:ok, Restore.t(), t()} | :empty
  def undo(%__MODULE__{undo_entries: []}, _current_version, %Document{}), do: :empty

  def undo(%__MODULE__{} = history, current_version, %Document{} = current_document) do
    [{previous_version, previous_document, source} | remaining_undo] = history.undo_entries
    redo_entry = {current_version, current_document, source}

    new_history = %{
      history
      | undo_entries: remaining_undo,
        redo_entries: [redo_entry | history.redo_entries]
    }

    {:ok, Restore.new(previous_version, previous_document, source), new_history}
  end

  @doc "Returns the next document/version and updates history, or `:empty` when redo is unavailable."
  @spec redo(t(), version(), Document.t()) :: {:ok, Restore.t(), t()} | :empty
  def redo(%__MODULE__{redo_entries: []}, _current_version, %Document{}), do: :empty

  def redo(%__MODULE__{} = history, current_version, %Document{} = current_document) do
    [{next_version, next_document, source} | remaining_redo] = history.redo_entries
    undo_entry = {current_version, current_document, source}

    new_history = %{
      history
      | redo_entries: remaining_redo,
        undo_entries: cap_entries([undo_entry | history.undo_entries])
    }

    {:ok, Restore.new(next_version, next_document, source), new_history}
  end

  @doc "Clears undo and redo entries and resets coalescing state."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = history) do
    %{history | undo_entries: [], redo_entries: [], last_recorded_at: 0}
  end

  @doc "Resets the coalescing timer so the next recorded edit creates a new undo entry."
  @spec break_coalescing(t()) :: t()
  def break_coalescing(%__MODULE__{} = history) do
    %{history | last_recorded_at: 0}
  end

  @doc "Returns the source of the most recent undo entry, or `nil` if undo is unavailable."
  @spec last_undo_source(t()) :: edit_source() | nil
  def last_undo_source(%__MODULE__{undo_entries: []}), do: nil
  def last_undo_source(%__MODULE__{undo_entries: [{_version, _document, source} | _]}), do: source

  @doc "Returns the source of the most recent redo entry, or `nil` if redo is unavailable."
  @spec last_redo_source(t()) :: edit_source() | nil
  def last_redo_source(%__MODULE__{redo_entries: []}), do: nil
  def last_redo_source(%__MODULE__{redo_entries: [{_version, _document, source} | _]}), do: source

  @doc false
  @spec undo_count(t()) :: non_neg_integer()
  def undo_count(%__MODULE__{} = history), do: length(history.undo_entries)

  @doc false
  @spec redo_count(t()) :: non_neg_integer()
  def redo_count(%__MODULE__{} = history), do: length(history.redo_entries)

  @spec do_record_edit(t(), version(), Document.t(), edit_source(), integer(), integer()) :: t()
  defp do_record_edit(%__MODULE__{} = history, version, document, source, now, elapsed)
       when history.last_recorded_at == 0 or elapsed >= @coalesce_ms do
    entry = {version, document, source}

    %{
      history
      | undo_entries: cap_entries([entry | history.undo_entries]),
        redo_entries: [],
        last_recorded_at: now
    }
  end

  defp do_record_edit(%__MODULE__{} = history, _version, _document, _source, now, _elapsed) do
    %{history | redo_entries: [], last_recorded_at: now}
  end

  @spec cap_entries([entry()]) :: [entry()]
  defp cap_entries(entries), do: Enum.take(entries, @max_entries)
end
