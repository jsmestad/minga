defmodule Minga.RenderModel.UI.SplitSeparators do
  @moduledoc """
  GUI split separator geometry.
  """

  @type vertical_separator ::
          {col :: non_neg_integer(), start_row :: non_neg_integer(), end_row :: non_neg_integer()}
  @type horizontal_separator ::
          {row :: non_neg_integer(), col :: non_neg_integer(), width :: non_neg_integer(),
           filename :: String.t()}

  @enforce_keys [:border_color_rgb, :verticals, :horizontals]
  defstruct border_color_rgb: 0,
            verticals: [],
            horizontals: []

  @type t :: %__MODULE__{
          border_color_rgb: non_neg_integer(),
          verticals: [vertical_separator()],
          horizontals: [horizontal_separator()]
        }
end
