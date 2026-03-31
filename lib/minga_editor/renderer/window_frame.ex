defmodule MingaEditor.Renderer.WindowFrame do
  @moduledoc """
  Per-window layout computed for a single render pass.

  Bundles the viewport, gutter dimensions, buffer lines, cursor, and
  active/inactive status for one window. Built once per window per frame
  and passed to `build_render_ctx/3` to produce the `Renderer.Context`
  the line renderer consumes.
  """

  alias MingaEditor.Viewport

  @enforce_keys [:viewport, :gutter_w, :content_w, :cursor, :lines, :first_line, :is_active]
  defstruct [:viewport, :gutter_w, :content_w, :cursor, :lines, :first_line, :is_active]

  @type t :: %__MODULE__{
          viewport: Viewport.t(),
          gutter_w: non_neg_integer(),
          content_w: pos_integer(),
          cursor: {non_neg_integer(), non_neg_integer()},
          lines: [String.t()],
          first_line: non_neg_integer(),
          is_active: boolean()
        }
end
