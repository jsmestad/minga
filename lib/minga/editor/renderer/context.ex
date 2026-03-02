defmodule Minga.Editor.Renderer.Context do
  @moduledoc """
  Rendering context for a single render pass.

  Bundles the per-frame invariants that every line renderer needs:
  viewport geometry, visual selection bounds, search match positions,
  gutter width, and the active substitute-confirm match (if any).

  Built once per render call and threaded through the line rendering
  pipeline, keeping individual function signatures focused on the
  per-line values that actually vary (line text, screen row, buffer line).
  """

  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Editor.Viewport

  @enforce_keys [:viewport, :gutter_w, :content_w]
  defstruct viewport: nil,
            visual_selection: nil,
            search_matches: [],
            gutter_w: 0,
            content_w: 0,
            confirm_match: nil

  @typedoc """
  Represents the bounds of a visual selection for rendering.

  * `nil` — no active selection
  * `{:char, start_pos, end_pos}` — characterwise selection
  * `{:line, start_line, end_line}` — linewise selection
  """
  @type visual_selection ::
          nil
          | {:char, {non_neg_integer(), non_neg_integer()},
             {non_neg_integer(), non_neg_integer()}}
          | {:line, non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          viewport: Viewport.t(),
          visual_selection: visual_selection(),
          search_matches: [SearchHighlight.search_match()],
          gutter_w: non_neg_integer(),
          content_w: pos_integer(),
          confirm_match: SearchHighlight.search_match() | nil
        }
end
