defmodule Minga.RenderModel.UI.Picker.ActionMenu do
  @moduledoc false

  @type t :: %__MODULE__{
          actions: [String.t()],
          activation_ids: [non_neg_integer()],
          selected_index: non_neg_integer()
        }

  @enforce_keys [:actions, :selected_index]
  defstruct actions: [],
            activation_ids: [],
            selected_index: 0
end
