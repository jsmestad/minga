defmodule Minga.RenderModel.Window.GutterMetrics do
  @moduledoc """
  Window-scoped gutter sizing in terminal cell columns.
  """

  @enforce_keys [:line_number_width, :sign_col_width]
  defstruct line_number_width: 0,
            sign_col_width: 0

  @type t :: %__MODULE__{
          line_number_width: non_neg_integer(),
          sign_col_width: non_neg_integer()
        }

  @doc "Returns the total gutter width in cells."
  @spec total_width(t()) :: non_neg_integer()
  def total_width(%__MODULE__{} = metrics) do
    metrics.line_number_width + metrics.sign_col_width
  end
end
