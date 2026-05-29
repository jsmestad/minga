defmodule Minga.RenderModel.UI.ExtensionOverlay do
  @moduledoc """
  Semantic extension overlay model for GUI adapters.
  """

  alias Minga.RenderModel.UI.ExtensionOverlay.Entry

  @type t :: %__MODULE__{
          entries: [Entry.t()]
        }

  defstruct entries: []
end
