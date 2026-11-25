defmodule Minga.Buffer.UndoHistory.Entry do
  @moduledoc """
  One step on your undo or redo stack.

  An entry names the provenance group that holds the step's text, so undo and redo find that text wherever later edits moved it. It also remembers the buffer version and cursor to restore, and the two history ticks that say when restoring them is exact: only when nothing else changed the document since the step, so the document is exactly the one that version named.

  `Minga.Buffer.UndoHistory` is the only writer of entries.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Provenance

  @enforce_keys [:group, :source, :version, :cursor, :tick_from, :tick_to]
  defstruct [:group, :source, :version, :cursor, :tick_from, :tick_to]

  @typedoc "A history tick: the identity of one change to the document."
  @type tick :: non_neg_integer()

  @typedoc """
  An undo or redo step.

  `version` and `cursor` are restored when the entry is popped while the history is still at `tick_from`; the history then moves to `tick_to`.
  """
  @type t :: %__MODULE__{
          group: Provenance.group_id(),
          source: EditSource.undo_source(),
          version: non_neg_integer(),
          cursor: Document.position(),
          tick_from: tick(),
          tick_to: tick()
        }
end
