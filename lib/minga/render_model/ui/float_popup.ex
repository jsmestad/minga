defmodule Minga.RenderModel.UI.FloatPopup do
  @moduledoc """
  Semantic floating popup model for GUI adapters.
  """

  @type t :: %__MODULE__{
          visible?: boolean(),
          title: String.t(),
          lines: [String.t()],
          # Preferred native maximum size, retained as width/height for the current wire format.
          width: non_neg_integer(),
          height: non_neg_integer()
        }

  defstruct visible?: false,
            title: "",
            lines: [],
            width: 0,
            height: 0
end
