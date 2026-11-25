defmodule Minga.RenderModel.UI.EmptyState.Section do
  @moduledoc """
  One titled section of the project home. `empty` is the muted line shown when the section has no rows ("Nothing opened here yet.").
  """

  alias Minga.RenderModel.UI.EmptyState.Item

  @typedoc "Home section identity, in display order."
  @type id :: :recent | :projects | :tasks | :next

  @type t :: %__MODULE__{
          id: id(),
          title: String.t(),
          empty: String.t(),
          items: [Item.t()]
        }

  @enforce_keys [:id]
  defstruct id: nil,
            title: "",
            empty: "",
            items: []
end
