defmodule Minga.RenderModel.UI.CellLayer do
  @moduledoc """
  Cell-grid UI layer for the TUI adapter.

  The retained render model is the canonical visible truth. This struct is a temporary compatibility boundary for legacy non-buffer window cells that have not yet moved to semantic window models. Shared chrome must not use this layer; new shared UI belongs in Semantic UI models and semantic frontend adapters.
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
