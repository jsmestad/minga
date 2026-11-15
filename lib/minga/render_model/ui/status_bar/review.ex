defmodule Minga.RenderModel.UI.StatusBar.Review do
  @moduledoc "Persistent read-only Review status and its exact committed action offer."

  @enforce_keys [:path, :freshness, :generation, :item_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: String.t(),
          freshness: :current | :stale,
          generation: non_neg_integer(),
          item_id: String.t()
        }
end
