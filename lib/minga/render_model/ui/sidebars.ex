defmodule Minga.RenderModel.UI.Sidebars do
  @moduledoc """
  Semantic sidebar metadata model for GUI adapters.
  """

  alias Minga.RenderModel.UI.Sidebars.Sidebar

  @type t :: %__MODULE__{
          active_id: String.t(),
          sidebars: [Sidebar.t()]
        }

  defstruct active_id: "",
            sidebars: []
end
