defmodule Minga.RenderModel.UI.GutterSeparator do
  @moduledoc """
  GUI gutter separator state.
  """

  @enforce_keys [:col, :color_rgb]
  defstruct col: 0,
            color_rgb: 0

  @type t :: %__MODULE__{
          col: non_neg_integer(),
          color_rgb: non_neg_integer()
        }
end
