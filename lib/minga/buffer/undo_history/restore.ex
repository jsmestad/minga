defmodule Minga.Buffer.UndoHistory.Restore do
  @moduledoc """
  Document snapshot returned by an undo or redo transition.

  The history owns which snapshot should be restored. The buffer process owns applying that snapshot to the live buffer state.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditSource

  @enforce_keys [:version, :document, :source]
  defstruct [:version, :document, :source]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          document: Document.t(),
          source: EditSource.undo_source()
        }

  @doc "Creates a restore snapshot."
  @spec new(non_neg_integer(), Document.t(), EditSource.undo_source()) :: t()
  def new(version, %Document{} = document, source)
      when source in [:user, :agent, :lsp, :recovery] do
    %__MODULE__{version: version, document: document, source: source}
  end
end
