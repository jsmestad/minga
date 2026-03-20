defmodule Minga.LSP.DocumentHighlight do
  @moduledoc """
  A document highlight range from the LSP server.

  Represents a single occurrence of a symbol in the current buffer,
  returned by `textDocument/documentHighlight`. The `kind` field
  distinguishes read references from write references.
  """

  @enforce_keys [:start_line, :start_col, :end_line, :end_col, :kind]
  defstruct [:start_line, :start_col, :end_line, :end_col, :kind]

  @typedoc "LSP document highlight kind."
  @type kind :: :text | :read | :write

  @type t :: %__MODULE__{
          start_line: non_neg_integer(),
          start_col: non_neg_integer(),
          end_line: non_neg_integer(),
          end_col: non_neg_integer(),
          kind: kind()
        }

  @doc "Parses an LSP DocumentHighlight JSON object into a struct."
  @spec from_lsp(map()) :: t()
  def from_lsp(%{"range" => range} = hl) do
    start_pos = range["start"]
    end_pos = range["end"]

    kind =
      case hl["kind"] do
        2 -> :read
        3 -> :write
        _ -> :text
      end

    %__MODULE__{
      start_line: start_pos["line"],
      start_col: start_pos["character"],
      end_line: end_pos["line"],
      end_col: end_pos["character"],
      kind: kind
    }
  end
end
