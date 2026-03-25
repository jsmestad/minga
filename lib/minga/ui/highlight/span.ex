defmodule Minga.UI.Highlight.Span do
  @moduledoc """
  A highlight span representing a styled region of text.

  Spans are produced by both tree-sitter (via the parser Port) and LSP
  semantic tokens. They share this common shape so the highlight sweep
  can merge them by layer priority without caring about the source.

  The `layer` field controls precedence: higher layers override lower ones
  when spans overlap. Tree-sitter uses layer 0-1, LSP semantic tokens
  use layer 2.
  """

  @typedoc "A highlight span."
  @type t :: %__MODULE__{
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          capture_id: non_neg_integer(),
          pattern_index: non_neg_integer(),
          layer: non_neg_integer()
        }

  @enforce_keys [:start_byte, :end_byte, :capture_id]
  defstruct start_byte: 0,
            end_byte: 0,
            capture_id: 0,
            pattern_index: 0,
            layer: 0

  @doc "Creates a new highlight span."
  @spec new(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def new(start_byte, end_byte, capture_id, pattern_index \\ 0, layer \\ 0) do
    %__MODULE__{
      start_byte: start_byte,
      end_byte: end_byte,
      capture_id: capture_id,
      pattern_index: pattern_index,
      layer: layer
    }
  end
end
