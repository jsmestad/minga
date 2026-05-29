defmodule Minga.RenderModel.UI.ExtensionPanel do
  @moduledoc """
  Semantic extension panel model for GUI adapters.
  """

  alias Minga.RenderModel.UI.ExtensionPanel.Panel

  @type t :: %__MODULE__{
          panels: [Panel.t()]
        }

  defstruct panels: []
end
