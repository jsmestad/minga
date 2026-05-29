defmodule Minga.RenderModel.UI.ExtensionPanel.Content.Progress do
  @moduledoc """
  Progress content block in a GUI extension panel.
  """

  @type t :: %__MODULE__{
          label: String.t(),
          percent: number()
        }

  @enforce_keys [:label, :percent]
  defstruct [:label, :percent]
end
