defmodule Minga.Agent.SessionMetadata do
  @moduledoc """
  Lightweight session metadata for the session picker and history display.

  Contains just enough information to render a session list entry without
  loading the full conversation history. Built from session state via
  `from_state/1` or loaded from the session store.
  """

  @typedoc "Session metadata."
  @type t :: %__MODULE__{
          id: String.t(),
          model_name: String.t(),
          created_at: DateTime.t(),
          message_count: non_neg_integer(),
          first_prompt: String.t() | nil,
          cost: float(),
          status: Minga.Agent.Session.status()
        }

  @enforce_keys [:id, :model_name, :created_at]
  defstruct id: nil,
            model_name: nil,
            created_at: nil,
            message_count: 0,
            first_prompt: nil,
            cost: 0.0,
            status: :idle
end
