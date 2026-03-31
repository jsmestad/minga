defmodule MingaEditor.SemanticWindow.VisualRow do
  @moduledoc """
  A single visual row in the semantic window.

  Represents one display row as the GUI should render it. The BEAM has
  already resolved word wrap, folding, virtual text splicing, and conceal
  ranges. The `text` field contains the final composed UTF-8 string.

  ## Row Types

  - `:normal` — a regular buffer line (or the visible portion after wrapping)
  - `:fold_start` — a fold summary line (text includes the fold indicator)
  - `:virtual_line` — an injected virtual line from decorations (no buffer content)
  - `:block` — a block decoration row rendered by a callback
  - `:wrap_continuation` — a continuation row from word wrapping
  """

  alias MingaEditor.SemanticWindow.Span

  @enforce_keys [:row_type, :buf_line, :text, :spans]
  defstruct row_type: :normal,
            buf_line: 0,
            text: "",
            spans: [],
            content_hash: 0

  @type row_type :: :normal | :fold_start | :virtual_line | :block | :wrap_continuation

  @type t :: %__MODULE__{
          row_type: row_type(),
          buf_line: non_neg_integer(),
          text: String.t(),
          spans: [Span.t()],
          content_hash: non_neg_integer()
        }

  @doc "Computes a content hash for cache invalidation."
  @spec compute_hash(String.t(), [Span.t()]) :: non_neg_integer()
  def compute_hash(text, spans) do
    :erlang.phash2({text, spans})
  end
end
