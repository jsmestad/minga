defmodule Minga.LSP.SemanticToken do
  @moduledoc """
  A decoded semantic token with absolute position.

  Produced by decoding the delta-encoded token array from an LSP server's
  `textDocument/semanticTokens` response. Consumed by `SemanticTokens.to_spans/5`
  to convert into `Highlight.Span` structs for the highlight sweep.
  """

  @typedoc "A decoded semantic token."
  @type t :: %__MODULE__{
          line: non_neg_integer(),
          start_char: non_neg_integer(),
          length: non_neg_integer(),
          type: String.t(),
          modifiers: [String.t()]
        }

  @enforce_keys [:line, :start_char, :length, :type]
  defstruct line: 0,
            start_char: 0,
            length: 0,
            type: "",
            modifiers: []
end
