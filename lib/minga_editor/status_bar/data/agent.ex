defmodule MingaEditor.StatusBar.Data.Agent do
  @moduledoc false

  alias MingaEditor.State.Agent, as: AgentState

  @type t :: %__MODULE__{
          model_name: String.t(),
          session_status: AgentState.status(),
          message_count: non_neg_integer()
        }

  @enforce_keys [:model_name, :session_status, :message_count]
  defstruct @enforce_keys
end
