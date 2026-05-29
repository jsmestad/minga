defmodule Minga.RenderModel.UI.HoverPopup.Line do
  @moduledoc """
  One markdown line in the GUI hover popup model.
  """

  alias Minga.RenderModel.UI.HoverPopup.Segment

  @type line_type :: atom() | {atom(), term()}

  @type t :: %__MODULE__{
          segments: [Segment.t()],
          line_type: line_type()
        }

  defstruct segments: [],
            line_type: :text
end
