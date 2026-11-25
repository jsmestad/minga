defmodule Minga.Buffer.Provenance.Run do
  @moduledoc """
  One contiguous piece of text with a single author and a single history.

  A run records the group that inserted it and every group that deleted it. Whether it is part of the document follows from those groups: a run is live when the group that inserted it is applied and no group that deleted it is applied. Undoing or rejecting a group only flips the group, and the runs it touched follow.

  `covered_by` lists the deleters in `deletions` whose deletion a cover added: they consumed a replacement and this text went with it. The run is dead because of them, but they never rewrote it, so they never block an undo or a reject. `swept_by` lists the deleters in `deletions` that deleted the run when it was already a tombstone strictly inside their range: they never removed it while it was visible. A direct deletion of visible text clears the group from both lists.

  `made_by` names the replacement (`Minga.Buffer.Provenance.Change`) that inserted the run, if it has a record, and `replaced_by` every replacement that marked it dead, newest first.

  A live run's text is in the document, so the run keeps only its length. A dead run (a tombstone) is not in the document, so it keeps its own text; restoring it puts that text back exactly. A tombstone takes no bytes in the document.

  `Minga.Buffer.Provenance` is the only writer of runs.
  """

  alias Minga.Buffer.Provenance.Change
  alias Minga.Buffer.Provenance.Locator

  @enforce_keys [:id, :bytes, :author]
  defstruct [
    :id,
    :bytes,
    :author,
    group: nil,
    deletions: [],
    overlaps: [],
    text: nil,
    live: true,
    made_by: nil,
    replaced_by: [],
    covered_by: [],
    swept_by: []
  ]

  @typedoc """
  Who wrote a run: you, Minga in a task, or nobody we know of.

  `:unattributed` is text that predates tracking: the file as it was loaded, text appended to a log buffer, or text changed on disk. `{:minga, :untasked}` is text an agent edit wrote without a task.
  """
  @type author :: :you | :unattributed | Minga.Buffer.Author.t() | {:minga, :untasked}

  @typedoc """
  An overlap mark on a run of a replacement's text: `{owner, group}`, where `owner` is the Minga group whose replacement it is and `group` deleted part of that replacement, or is `{:permanent, key}` once that group is final. It never affects whether the run is live; it only makes rejecting `owner` inexact.
  """
  @type overlap :: {group_id(), group_id() | {:permanent, term()}}

  @typedoc "A history group, as numbered by `Minga.Buffer.Provenance`."
  @type group_id :: pos_integer()

  @type t :: %__MODULE__{
          id: Locator.t(),
          bytes: pos_integer(),
          author: author(),
          group: group_id() | nil,
          deletions: [group_id()],
          overlaps: [overlap()],
          text: binary() | nil,
          live: boolean(),
          made_by: Change.id() | nil,
          replaced_by: [Change.id()],
          covered_by: [group_id()],
          swept_by: [group_id()]
        }

  @doc "Returns how many bytes the run takes in the document: its length when live, zero when it is a tombstone."
  @spec live_bytes(t()) :: non_neg_integer()
  def live_bytes(%__MODULE__{live: true, bytes: bytes}), do: bytes
  def live_bytes(%__MODULE__{live: false}), do: 0
end
