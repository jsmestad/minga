defmodule Minga.LSP.DocumentContext do
  @moduledoc """
  Identifies the exact client-side document representation used for an LSP request.

  Buffer revisions and LSP wire versions are independent counters. This value records their relationship without comparing their numbers.
  """

  @enforce_keys [:client, :buffer, :uri, :buffer_revision, :lsp_version, :encoding]
  defstruct [:client, :buffer, :uri, :buffer_revision, :lsp_version, :encoding]

  @type t :: %__MODULE__{
          client: pid(),
          buffer: pid(),
          uri: String.t(),
          buffer_revision: non_neg_integer(),
          lsp_version: pos_integer(),
          encoding: Minga.LSP.PositionEncoding.encoding()
        }
end
