defmodule Minga.RenderModel.UI.CellLayer do
  @moduledoc """
  Cell-grid UI layer for the TUI adapter.

  The retained render model is the canonical visible truth. Some TUI chrome still starts life as cell-grid draws because those surfaces have not all been promoted to semantic models yet. This struct narrows that compatibility layer to explicit adapter input instead of letting `DisplayList.Frame` remain the TUI pipeline product.
  """

  alias Minga.RenderModel.Cell

  @type t :: %__MODULE__{
          pre_window_cells: [Cell.t()],
          legacy_window_cells: [Cell.t()],
          post_window_cells: [Cell.t()],
          overlay_cells: [Cell.t()]
        }

  defstruct pre_window_cells: [],
            legacy_window_cells: [],
            post_window_cells: [],
            overlay_cells: []

  @doc "Returns all non-overlay chrome cells in draw order."
  @spec chrome_cells(t()) :: [Cell.t()]
  def chrome_cells(%__MODULE__{} = layer) do
    layer.pre_window_cells ++ layer.legacy_window_cells ++ layer.post_window_cells
  end
end
