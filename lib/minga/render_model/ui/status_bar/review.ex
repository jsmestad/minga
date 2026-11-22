defmodule Minga.RenderModel.UI.StatusBar.Review do
  @moduledoc "Persistent Review status and its exact committed action offer."

  @enforce_keys [:path, :freshness, :generation, :item_id]
  defstruct [{:conflict_index, nil} | @enforce_keys]

  @type t :: %__MODULE__{
          path: String.t(),
          freshness: :current | :stale,
          conflict_index: pos_integer() | nil,
          generation: non_neg_integer(),
          item_id: String.t()
        }
end
