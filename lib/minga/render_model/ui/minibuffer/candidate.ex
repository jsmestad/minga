defmodule Minga.RenderModel.UI.Minibuffer.Candidate do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          description: String.t(),
          match_score: non_neg_integer(),
          match_positions: [non_neg_integer()],
          annotation: String.t()
        }

  @enforce_keys [:label]
  defstruct id: "",
            label: "",
            description: "",
            match_score: 0,
            match_positions: [],
            annotation: ""
end
