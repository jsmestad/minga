defmodule MingaEditor.RenderModel.UI.CellLayerBuilder do
  @moduledoc """
  Builds the TUI cell-grid compatibility layer for `Minga.RenderModel.UI`.

  This keeps legacy cell-draw chrome as render-model data so the production TUI emit path can consume `Minga.RenderModel` instead of reaching back into `DisplayList.Frame` as the visible truth.
  """

  alias Minga.RenderModel.Cell
  alias Minga.RenderModel.UI.CellLayer
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.Frame
  alias MingaEditor.DisplayList.Overlay
  alias MingaEditor.DisplayList.WindowFrame
  alias MingaEditor.RenderPipeline.Chrome

  @doc "Builds TUI cell layers from composed frame compatibility data."
  @spec build(Frame.t(), Chrome.t() | nil) :: CellLayer.t()
  def build(%Frame{} = frame, chrome \\ nil) do
    chrome = chrome || chrome_from_frame(frame)

    %CellLayer{
      pre_window_cells: draws_to_cells(chrome.tab_bar ++ chrome.file_tree ++ frame.agentic_view),
      legacy_window_cells: legacy_window_cells(frame),
      post_window_cells:
        draws_to_cells(
          chrome.separators ++
            chrome.status_bar_draws ++
            chrome.agent_panel ++ chrome.minibuffer ++ (frame.splash || [])
        ),
      overlay_cells: overlays_to_cells(chrome.overlays)
    }
  end

  @spec chrome_from_frame(Frame.t()) :: Chrome.t()
  defp chrome_from_frame(%Frame{} = frame) do
    %Chrome{
      tab_bar: frame.tab_bar,
      file_tree: frame.file_tree,
      separators: frame.separators,
      status_bar_draws: frame.status_bar,
      agent_panel: frame.agent_panel,
      minibuffer: frame.minibuffer,
      overlays: frame.overlays
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

  @spec overlays_to_cells([Overlay.t()]) :: [Cell.t()]
  defp overlays_to_cells(overlays) do
    overlays
    |> Enum.flat_map(fn %Overlay{draws: draws} -> draws end)
    |> draws_to_cells()
  end

  @spec draws_to_cells([DisplayList.draw()]) :: [Cell.t()]
  defp draws_to_cells(draws) do
    Enum.map(draws, fn {row, col, text, face} -> Cell.new(row, col, text, face) end)
  end
end
