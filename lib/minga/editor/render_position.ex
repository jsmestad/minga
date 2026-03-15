defmodule Minga.Editor.RenderPosition do
  @moduledoc """
  Screen position context for rendering non-buffer-line entries (virtual
  lines, block decorations, fold placeholders).

  Bundles the per-frame screen coordinates that every decoration render
  function needs. Constructed once per render pass and threaded through
  the rendering helpers, replacing the 5-7 positional arguments that
  previously traveled together.
  """

  @enforce_keys [:screen_row, :gutter_w, :row_off, :col_off, :content_w]
  defstruct [:screen_row, :gutter_w, :row_off, :col_off, :content_w]

  @type t :: %__MODULE__{
          screen_row: non_neg_integer(),
          gutter_w: non_neg_integer(),
          row_off: non_neg_integer(),
          col_off: non_neg_integer(),
          content_w: pos_integer()
        }
end
