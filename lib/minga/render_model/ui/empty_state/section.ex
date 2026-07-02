defmodule Minga.RenderModel.UI.EmptyState.Section do
  @moduledoc false

  alias Minga.RenderModel.UI.EmptyState.Item

  @typedoc "Launchpad section identity, in display order."
  @type id :: :session | :recent | :start | :footer

  @type t :: %__MODULE__{
          id: id(),
          title: String.t(),
          items: [Item.t()]
        }

  @enforce_keys [:id]
  defstruct id: nil,
            title: "",
            items: []
end
