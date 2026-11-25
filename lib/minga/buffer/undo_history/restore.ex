defmodule Minga.Buffer.UndoHistory.Restore do
  @moduledoc """
  Document snapshot returned by an undo or redo transition.

  The history owns which snapshot should be restored. The buffer process owns applying that snapshot to the live buffer state.

  `version` is the buffer version the snapshot had before, when the transition returned exactly to that state, or `:advance` when the snapshot is a document no earlier version named and the buffer must take a new version.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditSource

  import EditSource, only: [is_undo_source: 1]

  @enforce_keys [:version, :document, :source]
  defstruct [:version, :document, :source]

  @type t :: %__MODULE__{
          version: non_neg_integer() | :advance,
          document: Document.t(),
          source: EditSource.undo_source()
        }

  @doc "Creates a restore snapshot."
  @spec new(non_neg_integer() | :advance, Document.t(), EditSource.undo_source()) :: t()
  def new(version, %Document{} = document, source)
      when (version == :advance or (is_integer(version) and version >= 0)) and
             is_undo_source(source) do
    %__MODULE__{version: version, document: document, source: source}
  end
end
