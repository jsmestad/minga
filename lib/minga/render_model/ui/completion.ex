defmodule Minga.RenderModel.UI.Completion do
  @moduledoc """
  Semantic completion popup model for GUI adapters.
  """

  alias Minga.RenderModel.UI.Completion.Item

  @type t :: %__MODULE__{
          visible?: boolean(),
          cursor_row: non_neg_integer(),
          cursor_col: non_neg_integer(),
          selected_offset: non_neg_integer(),
          items: [Item.t()]
        }

  defstruct visible?: false,
            cursor_row: 0,
            cursor_col: 0,
            selected_offset: 0,
            items: []
end
