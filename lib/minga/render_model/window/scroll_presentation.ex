defmodule Minga.RenderModel.Window.ScrollPresentation do
  @moduledoc """
  BEAM-authored metadata for client-local presentation scrolling.

  This is not editor state. The BEAM remains authoritative for the committed viewport and layout; frontends may use this metadata to move already committed rows inside the provided clip rect while they wait for the next committed frame.

  `visible_end_line` and `overscan_end_line` are exclusive bounds. The visible and overscan ranges are half-open line ranges: `start_line <= line < end_line`.
  """

  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Row

  @enforce_keys [
    :window_id,
    :reset_required,
    :anchor_top,
    :anchor_left,
    :anchor_visual_row_offset,
    :visible_start_line,
    :visible_end_line,
    :overscan_start_line,
    :overscan_end_line,
    :content_epoch,
    :layout_generation
  ]
  defstruct window_id: 0,
            reset_required: false,
            anchor_top: 0,
            anchor_left: 0,
            anchor_visual_row_offset: 0,
            visible_start_line: 0,
            visible_end_line: 0,
            overscan_start_line: 0,
            overscan_end_line: 0,
            content_epoch: 0,
            layout_generation: 0

  @type t :: %__MODULE__{
          window_id: non_neg_integer(),
          reset_required: boolean(),
          anchor_top: non_neg_integer(),
          anchor_left: non_neg_integer(),
          anchor_visual_row_offset: non_neg_integer(),
          visible_start_line: non_neg_integer(),
          visible_end_line: non_neg_integer(),
          overscan_start_line: non_neg_integer(),
          overscan_end_line: non_neg_integer(),
          content_epoch: non_neg_integer(),
          layout_generation: non_neg_integer()
        }

  @doc "Builds scroll presentation metadata from a render window when geometry is available."
  @spec from_window(Window.t()) :: t() | nil
  def from_window(%Window{geometry: nil}), do: nil

  def from_window(%Window{geometry: %PaneGeometry{} = geometry} = window) do
    {overscan_start_line, overscan_end_line} =
      line_range(window.rows, geometry.viewport.top, window.contiguous_rows)

    visible_start_line = max(geometry.viewport.top, overscan_start_line)
    visible_end_line = min(visible_start_line + geometry.viewport.rows, overscan_end_line)

    %__MODULE__{
      window_id: window.window_id,
      reset_required: window.full_refresh,
      anchor_top: geometry.viewport.top,
      anchor_left: geometry.viewport.left,
      anchor_visual_row_offset: geometry.viewport.visual_row_offset,
      visible_start_line: visible_start_line,
      visible_end_line: visible_end_line,
      overscan_start_line: overscan_start_line,
      overscan_end_line: overscan_end_line,
      content_epoch: window.content_epoch,
      layout_generation: layout_generation(geometry)
    }
  end

  @spec line_range([Row.t()], non_neg_integer(), boolean()) ::
          {non_neg_integer(), non_neg_integer()}
  defp line_range([], fallback_line, _contiguous?), do: {fallback_line, fallback_line}

  # Contiguous non-wrapped sequential rows are consecutive buffer lines, so the
  # half-open range is arithmetic from the first row's buf_line and the row count.
  # This avoids folding over the whole (possibly full-document) row list every
  # frame; `length/1` is a cheap BIF walk rather than a per-row min/max reduce.
  defp line_range([%Row{buf_line: first} | _] = rows, _fallback_line, true) do
    {first, first + length(rows)}
  end

  # Wrapped or folded rows are not 1:1 with buffer lines (wrap continuations share
  # a buf_line, folds skip hidden lines), so fold for the true min/max.
  defp line_range(rows, _fallback_line, false) do
    {first, last} =
      Enum.reduce(rows, {nil, nil}, fn %Row{buf_line: line}, {min_line, max_line} ->
        {min_line(min_line, line), max_line(max_line, line)}
      end)

    {first, last + 1}
  end

  @spec min_line(non_neg_integer() | nil, non_neg_integer()) :: non_neg_integer()
  defp min_line(nil, line), do: line
  defp min_line(existing, line), do: min(existing, line)

  @spec max_line(non_neg_integer() | nil, non_neg_integer()) :: non_neg_integer()
  defp max_line(nil, line), do: line
  defp max_line(existing, line), do: max(existing, line)

  @spec layout_generation(PaneGeometry.t()) :: non_neg_integer()
  defp layout_generation(%PaneGeometry{} = geometry) do
    :erlang.phash2({
      geometry.total_rect,
      geometry.content_rect,
      geometry.text_rect,
      geometry.gutter_rect,
      geometry.clip_rect,
      geometry.viewport.rows,
      geometry.viewport.cols,
      geometry.viewport.left,
      geometry.gutter_metrics
    })
  end
end
