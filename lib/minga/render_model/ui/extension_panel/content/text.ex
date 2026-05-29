defmodule Minga.RenderModel.UI.ExtensionPanel.Content.Text do
  @moduledoc """
  Plain text content block in a GUI extension panel.
  """

  @type t :: %__MODULE__{text: String.t()}

  @enforce_keys [:text]
  defstruct [:text]
end
