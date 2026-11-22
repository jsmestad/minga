defmodule MingaAgent.Session.Transcript.Changes do
  @moduledoc """
  Coalesced current entries since one same-generation source cursor.

  Entries are ordered by ordinal. An entry with `created_revision` greater than
  the supplied cursor revision was appended; other entries revise existing IDs.
  Pin facts contain the latest membership for each affected active ID. New
  entries are unpinned unless a fact says otherwise. Only snapshots carry the
  full membership, including pins for IDs outside the active transcript.
  Metadata is the current atomic value, with exact per-field change flags.
  No intermediate payload versions are retained or returned.
  """

  alias MingaAgent.Session.Transcript.Cursor
  alias MingaAgent.Session.Transcript.Entry
  alias MingaAgent.TurnUsage

  @enforce_keys [
    :cursor,
    :entries,
    :pin_changes,
    :usage,
    :last_changed_at,
    :next_id,
    :count,
    :usage_changed?,
    :timestamp_changed?
  ]
  defstruct @enforce_keys

  @type pin_fact :: {pos_integer(), boolean()}

  @type t :: %__MODULE__{
          cursor: Cursor.t(),
          entries: [Entry.t()],
          pin_changes: [pin_fact()],
          usage: TurnUsage.t(),
          last_changed_at: DateTime.t(),
          next_id: pos_integer(),
          count: non_neg_integer(),
          usage_changed?: boolean(),
          timestamp_changed?: boolean()
        }

  @type metadata_changes :: %{
          usage_changed?: boolean(),
          timestamp_changed?: boolean()
        }

  @doc "Constructs current changed entries and exact metadata change facts."
  @spec new(
          Cursor.t(),
          [Entry.t()],
          [pin_fact()],
          TurnUsage.t(),
          DateTime.t(),
          pos_integer(),
          non_neg_integer(),
          metadata_changes()
        ) :: t()
  def new(
        cursor,
        entries,
        pin_changes,
        usage,
        changed_at,
        next_id,
        count,
        %{
          usage_changed?: usage_changed?,
          timestamp_changed?: timestamp_changed?
        }
      ) do
    %__MODULE__{
      cursor: cursor,
      entries: entries,
      pin_changes: pin_changes,
      usage: usage,
      last_changed_at: changed_at,
      next_id: next_id,
      count: count,
      usage_changed?: usage_changed?,
      timestamp_changed?: timestamp_changed?
    }
  end
end
