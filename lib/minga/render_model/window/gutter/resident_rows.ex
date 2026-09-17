defmodule Minga.RenderModel.Window.Gutter.ResidentRows do
  @moduledoc "A complete sequential gutter represented by its normal-row baseline and semantic exceptions."

  alias Minga.RenderModel.Window.GutterEntry

  @enforce_keys [:content_epoch, :line_count, :overrides]
  defstruct [:content_epoch, :line_count, :overrides]

  @type t :: %__MODULE__{
          content_epoch: non_neg_integer(),
          line_count: non_neg_integer(),
          overrides: [GutterEntry.t()]
        }
end
