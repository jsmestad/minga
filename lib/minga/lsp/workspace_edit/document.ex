defmodule Minga.LSP.WorkspaceEdit.Document do
  @moduledoc """
  One ordered `TextDocumentEdit` from an LSP WorkspaceEdit.

  The value preserves the server's URI, optional wire version, and raw edit order. Range conversion remains owned by `Minga.LSP.TextEdit` because it requires an immutable document snapshot and the producing client's negotiated encoding.
  """

  @enforce_keys [:uri, :path, :version, :edits]
  defstruct [:uri, :path, :version, :edits]

  @type t :: %__MODULE__{
          uri: String.t(),
          path: String.t(),
          version: non_neg_integer() | nil,
          edits: [map()]
        }
end
