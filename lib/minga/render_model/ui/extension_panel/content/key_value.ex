defmodule Minga.RenderModel.UI.ExtensionPanel.Content.KeyValue do
  @moduledoc """
  Key-value content block in a GUI extension panel.
  """

  @type pair :: {String.t(), String.t()}

  @type t :: %__MODULE__{pairs: [pair()]}

  @enforce_keys [:pairs]
  defstruct [:pairs]
end
