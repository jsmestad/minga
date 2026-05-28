defmodule Minga.RenderModel.Window.HitRegion do
  @moduledoc """
  Window-scoped input hit region authored by the BEAM.
  """

  @type kind :: :text | :gutter | :fold_control | :modeline | :divider
  @type rect ::
          {row :: non_neg_integer(), col :: non_neg_integer(), width :: non_neg_integer(),
           height :: non_neg_integer()}

  @enforce_keys [:kind, :rect, :window_id]
  defstruct kind: :text,
            rect: {0, 0, 0, 0},
            window_id: 0,
            target: nil

  @type t :: %__MODULE__{
          kind: kind(),
          rect: rect(),
          window_id: non_neg_integer(),
          target: term()
        }
end
