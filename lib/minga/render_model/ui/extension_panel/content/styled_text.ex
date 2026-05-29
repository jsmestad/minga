defmodule Minga.RenderModel.UI.ExtensionPanel.Content.StyledText do
  @moduledoc """
  Styled text content block in a GUI extension panel.
  """

  alias Minga.RenderModel.UI.ExtensionPanel.Content.StyledRun

  @type t :: %__MODULE__{runs: [StyledRun.t()]}

  @enforce_keys [:runs]
  defstruct [:runs]
end
