defmodule Minga.RenderModel.UI.ExtensionPanel.Content.TreeNode do
  @moduledoc """
  One node in a GUI extension panel tree content block.
  """

  @type t :: %__MODULE__{
          label: String.t(),
          expanded?: boolean(),
          children: [t()]
        }

  @enforce_keys [:label, :expanded?, :children]
  defstruct [:label, :expanded?, :children]
end
