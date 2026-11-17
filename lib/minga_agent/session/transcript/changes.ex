defmodule MingaAgent.Session.Transcript.Changes do
  @moduledoc """
  Coalesced current entries since one same-generation source cursor.

  Entries are ordered by ordinal. An entry with `created_revision` greater than
  the supplied cursor revision was appended; other entries revise existing IDs.
  Metadata is the current atomic value, with exact per-field change flags.
  No intermediate payload versions are retained or returned.
  """

  alias MingaAgent.Session.Transcript.Cursor
  alias MingaAgent.Session.Transcript.Entry
  alias MingaAgent.TurnUsage

  @enforce_keys [
    :cursor,
    :entries,
    :pinned_ids,
    :usage,
    :last_changed_at,
    :next_id,
    :count,
    :pins_changed?,
    :usage_changed?,
    :timestamp_changed?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          cursor: Cursor.t(),
          entries: [Entry.t()],
          pinned_ids: MapSet.t(pos_integer()),
          usage: TurnUsage.t(),
          last_changed_at: DateTime.t(),
          next_id: pos_integer(),
          count: non_neg_integer(),
          pins_changed?: boolean(),
          usage_changed?: boolean(),
          timestamp_changed?: boolean()
        }

  @type metadata_changes :: %{
          pins_changed?: boolean(),
          usage_changed?: boolean(),
          timestamp_changed?: boolean()
        }

  @doc "Constructs current changed entries and exact metadata change facts."
  @spec new(
          Cursor.t(),
          [Entry.t()],
          MapSet.t(pos_integer()),
          TurnUsage.t(),
          DateTime.t(),
          pos_integer(),
          non_neg_integer(),
          metadata_changes()
        ) :: t()
  def new(
        cursor,
        entries,
        pins,
        usage,
        changed_at,
        next_id,
        count,
        %{
          pins_changed?: pins_changed?,
          usage_changed?: usage_changed?,
          timestamp_changed?: timestamp_changed?
        }
      ) do
    %__MODULE__{
      cursor: cursor,
      entries: entries,
      pinned_ids: pins,
      usage: usage,
      last_changed_at: changed_at,
      next_id: next_id,
      count: count,
      pins_changed?: pins_changed?,
      usage_changed?: usage_changed?,
      timestamp_changed?: timestamp_changed?
    }
  end
end
