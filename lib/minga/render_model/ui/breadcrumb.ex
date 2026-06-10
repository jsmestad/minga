defmodule Minga.RenderModel.UI.Breadcrumb do
  @moduledoc false

  @typedoc """
  Semantic breadcrumb model. `file_path` and `root` are the source inputs;
  `segments` is the wire-ready path segment list the Layer 2 builder derives
  (Path.relative_to/split), which the adapter passes straight to the generated
  `encode_gui_breadcrumb/1`.
  """
  @type t :: %__MODULE__{
          file_path: String.t() | nil,
          root: String.t(),
          segments: [String.t()]
        }

  @enforce_keys [:root]
  defstruct file_path: nil, root: nil, segments: []
end
