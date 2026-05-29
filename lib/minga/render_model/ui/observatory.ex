defmodule Minga.RenderModel.UI.Observatory do
  @moduledoc """
  Semantic BEAM observatory model for GUI adapters.
  """

  alias Minga.RenderModel.UI.Observatory.Node

  @type t :: %__MODULE__{
          visible?: boolean(),
          nodes: [Node.t()]
        }

  defstruct visible?: false,
            nodes: []
end
