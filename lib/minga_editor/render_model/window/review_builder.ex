defmodule MingaEditor.RenderModel.Window.ReviewBuilder do
  @moduledoc "Builds read-only reviews through the ordinary resident window model."

  alias Minga.Editing.Scroll
  alias Minga.RenderModel.Window, as: WindowModel
  alias Minga.RenderModel.Window.GutterMetrics
  alias Minga.RenderModel.Window.HitRegion
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Viewport, as: ViewportModel
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Layout
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.RenderModel.Window.ReviewLayout
  alias MingaEditor.RenderModel.Window.ReviewProjection
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Viewport

  @type result ::
          {:ok, WindowModel.t(), RenderWindow.t()}
          | :not_visible
          | {:error, :review_unavailable | :row_slot_capacity}

  @doc "Projects the entire navigable review while preserving frontend-provided body fit."
  @spec build(
          RenderWindow.t(),
          Preview.t(),
          Layout.window_layout(),
          ReviewLayout.t(),
          Runtime.review_scope() | nil
        ) :: result()
  def build(_window, _preview, %{content: {_row, _col, 0, _height}}, _layout, _scope),
    do: :not_visible

  def build(_window, _preview, %{content: {_row, _col, _width, 0}}, _layout, _scope),
    do: :not_visible

  def build(_window, _preview, _window_layout, _layout, nil), do: {:error, :review_unavailable}

  def build(window, preview, window_layout, layout, scope) do
    with {:ok, projection, delta, window} <-
           RenderWindow.project_review(window, preview, scope, layout) do
      {_row, _col, _width, height} = window_layout.content
      top = Scroll.resolve(preview.scroll, projection.row_count, height)
      viewport = Viewport.put_top_visual(Viewport.new(height, layout.text_width, 0), top, 0, 1)
      window = RenderWindow.observe_review_frame(window, viewport, top)

      {window, epoch, full_refresh?} =
        RenderWindow.prepare_render_epoch(window, {:agent_review, projection.compatibility})

      geometry = geometry(window.id, window_layout, viewport, projection)

      model = %WindowModel{
        window_id: window.id,
        content_kind: :agent_review,
        rect: window_layout.content,
        rows: projection.rows,
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block,
        cursor_visible: false,
        accessibility_label: review_label(projection.review),
        accessibility_generation: window.accessibility_generation,
        geometry: geometry,
        content_epoch: epoch,
        full_refresh: full_refresh?,
        contiguous_rows: false,
        content_digest: projection.content_digest,
        row_delta: delta,
        row_store_mode: {:resident, projection.row_count},
        scroll_seq: RenderWindow.scroll_seq(window)
      }

      {:ok, model, window}
    end
  end

  @spec review_label(MingaEditor.Agent.DiffReview.t()) :: String.t()
  defp review_label(%{fork_revision: nil, path: path}), do: "Read-only review: #{path}"

  defp review_label(%{path: path}),
    do: "Fork conflict review: #{path}. y accepts; x keeps your version."

  @spec geometry(RenderWindow.id(), Layout.window_layout(), Viewport.t(), ReviewProjection.t()) ::
          PaneGeometry.t()
  defp geometry(window_id, window_layout, viewport, projection) do
    {row, col, _width, height} = rect = window_layout.content
    text_rect = {row, col, viewport.cols, height}

    %PaneGeometry{
      window_id: window_id,
      total_rect: Map.get(window_layout, :total, rect),
      content_rect: rect,
      text_rect: text_rect,
      gutter_rect: {row, col, 0, height},
      clip_rect: text_rect,
      viewport: %ViewportModel{
        top: viewport.top,
        left: 0,
        rows: Viewport.content_rows(viewport),
        cols: viewport.cols,
        total_lines: projection.row_count,
        visual_row_offset: viewport.visual_row_offset,
        total_visual_rows: projection.row_count
      },
      gutter_metrics: %GutterMetrics{line_number_width: 0, sign_col_width: 0},
      hit_regions: [
        %HitRegion{
          kind: :text,
          rect: text_rect,
          window_id: window_id,
          target: %{window_id: window_id}
        }
      ]
    }
  end
end
