defmodule Minga.RenderModel.UI.Picker.ActionMenu do
  @moduledoc false

  @type t :: %__MODULE__{
          actions: [String.t()],
          selected_index: non_neg_integer()
        }

  @enforce_keys [:actions, :selected_index]
  defstruct actions: [],
            selected_index: 0
end
