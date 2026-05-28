defmodule Minga.RenderModel.Window.Viewport do
  @moduledoc """
  Window-scoped viewport summary for GUI rendering and hit testing.
  """

  @enforce_keys [:top, :left, :rows, :cols, :total_lines]
  defstruct top: 0,
            left: 0,
            rows: 0,
            cols: 0,
            total_lines: 0,
            visual_row_offset: 0,
            total_visual_rows: 0

  @type t :: %__MODULE__{
          top: non_neg_integer(),
          left: non_neg_integer(),
          rows: non_neg_integer(),
          cols: non_neg_integer(),
          total_lines: non_neg_integer(),
          visual_row_offset: non_neg_integer(),
          total_visual_rows: non_neg_integer()
        }
end
