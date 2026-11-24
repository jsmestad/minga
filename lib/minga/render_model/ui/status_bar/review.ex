defmodule Minga.RenderModel.UI.StatusBar.Review do
  @moduledoc """
  Persistent Review status and its exact committed action offer.

  A fork conflict offer also carries the key hints for its two decisions, in the active editing model, so frontends label "Keep mine" and "Use Agent version" with keys the BEAM binds.
  """

  @enforce_keys [:path, :freshness, :generation, :item_id]
  defstruct [{:conflict_index, nil}, {:keep_mine_key, ""}, {:use_agent_key, ""} | @enforce_keys]

  @type t :: %__MODULE__{
          path: String.t(),
          freshness: :current | :stale,
          conflict_index: pos_integer() | nil,
          keep_mine_key: String.t(),
          use_agent_key: String.t(),
          generation: non_neg_integer(),
          item_id: String.t()
        }
end
