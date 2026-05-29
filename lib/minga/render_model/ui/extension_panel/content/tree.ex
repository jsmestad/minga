defmodule Minga.RenderModel.UI.ExtensionPanel.Content.Tree do
  @moduledoc """
  Tree content block in a GUI extension panel.
  """

  alias Minga.RenderModel.UI.ExtensionPanel.Content.TreeNode

  @type t :: %__MODULE__{nodes: [TreeNode.t()]}

  @enforce_keys [:nodes]
  defstruct [:nodes]
end
