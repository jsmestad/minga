defmodule MingaEditor.RenderModel.UI.CellLayerBuilder do
  @moduledoc """
  Builds the TUI cell-grid compatibility layer for `Minga.RenderModel.UI`.

  This keeps the remaining legacy cell-draw window compatibility as render-model data so the production TUI emit path can consume `Minga.RenderModel` instead of reaching back into `DisplayList.Frame` as the visible truth.

  Shared chrome must not be routed through this layer. It must be represented as Semantic UI and encoded by the semantic adapter.
  """

  alias Minga.RenderModel.Cell
  alias Minga.RenderModel.UI.CellLayer
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.Frame
  alias MingaEditor.DisplayList.WindowFrame
  alias MingaEditor.RenderPipeline.Chrome

  @doc "Builds TUI cell layers from composed frame compatibility data."
  @spec build(Frame.t(), Chrome.t() | nil) :: CellLayer.t()
  def build(%Frame{} = frame, _chrome \\ nil) do
    %CellLayer{
      legacy_window_cells: legacy_window_cells(frame)
    }
  end

  @spec legacy_window_cells(Frame.t()) :: [Cell.t()]
  defp legacy_window_cells(%Frame{} = frame) do
    Enum.flat_map(frame.windows, fn
      %WindowFrame{window_model: %{content_kind: :agent_chat}} = window_frame ->
        window_lines_to_cells(window_frame)

      %WindowFrame{window_model: nil} = window_frame ->
        window_lines_to_cells(window_frame)

      %WindowFrame{} ->
        []
    end)
  end

  @spec window_lines_to_cells(WindowFrame.t()) :: [Cell.t()]
  defp window_lines_to_cells(%WindowFrame{} = window_frame) do
    {row_off, col_off, _width, _height} = window_frame.rect

    (DisplayList.layer_to_draws(window_frame.gutter) ++
       DisplayList.layer_to_draws(window_frame.lines) ++
       DisplayList.layer_to_draws(window_frame.tilde_lines))
    |> DisplayList.offset_draws(row_off, col_off)
    |> draws_to_cells()
  end

  @spec draws_to_cells([DisplayList.draw()]) :: [Cell.t()]
  defp draws_to_cells(draws) do
    Enum.map(draws, fn {row, col, text, face} -> Cell.new(row, col, text, face) end)
  end
end
