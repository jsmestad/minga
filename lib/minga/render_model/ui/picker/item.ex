defmodule Minga.RenderModel.UI.Picker.Item do
  @moduledoc false

  @type id :: term()

  @type t :: %__MODULE__{
          id: id(),
          label: String.t(),
          description: String.t(),
          annotation: String.t(),
          search_text: String.t(),
          icon_color: non_neg_integer() | nil,
          two_line?: boolean(),
          match_positions: [non_neg_integer()],
          marked?: boolean()
        }

  @enforce_keys [:id, :label]
  defstruct id: nil,
            label: "",
            description: "",
            annotation: "",
            search_text: "",
            icon_color: nil,
            two_line?: false,
            match_positions: [],
            marked?: false
end
