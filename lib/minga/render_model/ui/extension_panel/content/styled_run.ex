defmodule Minga.RenderModel.UI.ExtensionPanel.Content.StyledRun do
  @moduledoc """
  One styled text run in a GUI extension panel.
  """

  @type attrs :: %{bold?: boolean(), italic?: boolean()}

  @type t :: %__MODULE__{
          text: String.t(),
          fg: non_neg_integer(),
          attrs: attrs()
        }

  @enforce_keys [:text, :fg, :attrs]
  defstruct [:text, :fg, :attrs]
end
