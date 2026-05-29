defmodule Minga.RenderModel.UI.SignatureHelp.Signature do
  @moduledoc """
  One callable signature in the GUI signature help model.
  """

  alias Minga.RenderModel.UI.SignatureHelp.Parameter

  @type t :: %__MODULE__{
          label: String.t(),
          documentation: String.t(),
          parameters: [Parameter.t()]
        }

  defstruct label: "",
            documentation: "",
            parameters: []
end
