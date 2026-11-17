defmodule MingaAgent.Session.Transcript.Snapshot do
  @moduledoc "Ordered atomic source snapshot. Entries, identity, pins and metadata share one cursor."

  alias MingaAgent.Session.Transcript.Cursor
  alias MingaAgent.Session.Transcript.Entry
  alias MingaAgent.TurnUsage

  @enforce_keys [:cursor, :entries, :pinned_ids, :usage, :last_changed_at, :next_id, :count]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          cursor: Cursor.t(),
          entries: [Entry.t()],
          pinned_ids: MapSet.t(pos_integer()),
          usage: TurnUsage.t(),
          last_changed_at: DateTime.t(),
          next_id: pos_integer(),
          count: non_neg_integer()
        }

  @doc "Constructs an atomic snapshot from canonical source facts."
  @spec new(
          Cursor.t(),
          [Entry.t()],
          MapSet.t(pos_integer()),
          TurnUsage.t(),
          DateTime.t(),
          pos_integer(),
          non_neg_integer()
        ) :: t()
  def new(cursor, entries, pins, usage, changed_at, next_id, count) do
    %__MODULE__{
      cursor: cursor,
      entries: entries,
      pinned_ids: pins,
      usage: usage,
      last_changed_at: changed_at,
      next_id: next_id,
      count: count
    }
  end
end
