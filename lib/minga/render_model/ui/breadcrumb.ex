defmodule Minga.RenderModel.UI.Breadcrumb do
  @moduledoc false

  @typedoc """
  Semantic breadcrumb model. `segments` is the wire-ready path segment list the
  Layer 2 builder derives (Path.relative_to/split), which the adapter passes
  straight to the generated `encode_gui_breadcrumb/1`.
  """
  @type t :: %__MODULE__{segments: [String.t()]}

  @enforce_keys [:segments]
  defstruct segments: []
end
