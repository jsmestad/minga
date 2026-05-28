defmodule Minga.RenderModel.Window.PaneGeometry do
  @moduledoc """
  BEAM-authored pane geometry for one render-model window.

  Native GUI frontends use this as the authoritative source for pane ownership, clipping, and input hit testing. Pixel conversion remains frontend-owned, but the BEAM owns the cell-space rects and target regions.
  """

  alias Minga.RenderModel.Window.GutterMetrics
  alias Minga.RenderModel.Window.HitRegion
  alias Minga.RenderModel.Window.Viewport

  @type rect ::
          {row :: non_neg_integer(), col :: non_neg_integer(), width :: non_neg_integer(),
           height :: non_neg_integer()}

  @enforce_keys [
    :window_id,
    :total_rect,
    :content_rect,
    :text_rect,
    :gutter_rect,
    :clip_rect,
    :viewport,
    :gutter_metrics,
    :hit_regions
  ]
  defstruct window_id: 0,
            total_rect: {0, 0, 0, 0},
            content_rect: {0, 0, 0, 0},
            text_rect: {0, 0, 0, 0},
            gutter_rect: {0, 0, 0, 0},
            clip_rect: {0, 0, 0, 0},
            viewport: nil,
            gutter_metrics: nil,
            hit_regions: []

  @type t :: %__MODULE__{
          window_id: non_neg_integer(),
          total_rect: rect(),
          content_rect: rect(),
          text_rect: rect(),
          gutter_rect: rect(),
          clip_rect: rect(),
          viewport: Viewport.t(),
          gutter_metrics: GutterMetrics.t(),
          hit_regions: [HitRegion.t()]
        }
end
