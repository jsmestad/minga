defmodule Minga.RenderModel.UI.SignatureHelp.Parameter do
  @moduledoc """
  One callable parameter in the GUI signature help model.
  """

  @type t :: %__MODULE__{
          label: String.t(),
          documentation: String.t()
        }

  defstruct label: "",
            documentation: ""
end
