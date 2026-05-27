defmodule Minga.RenderModel.Window.IndentGuides do
  @moduledoc """
  Pre-resolved indent guide columns and per-line levels for one window.
  """

  @enforce_keys [:window_id, :tab_width, :active_guide_col, :guide_cols, :line_indent_levels]
  defstruct window_id: 0,
            tab_width: 0,
            active_guide_col: 0xFFFF,
            guide_cols: [],
            line_indent_levels: []

  @type t :: %__MODULE__{
          window_id: non_neg_integer(),
          tab_width: non_neg_integer(),
          active_guide_col: non_neg_integer(),
          guide_cols: [non_neg_integer()],
          line_indent_levels: [non_neg_integer()]
        }

  @doc "Returns an empty guide model for a window."
  @spec empty(non_neg_integer()) :: t()
  def empty(window_id),
    do: %__MODULE__{
      window_id: window_id,
      tab_width: 0,
      active_guide_col: 0xFFFF,
      guide_cols: [],
      line_indent_levels: []
    }
end
