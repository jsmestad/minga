defmodule MingaEditor.StatusBar.Data.Agent do
  @moduledoc false

  @typedoc "The active workspace's Agent status, as `MingaEditor.Agent.WorkspaceStatus` resolves it."
  @type session_status :: MingaEditor.Agent.WorkspaceStatus.t()

  @type t :: %__MODULE__{
          model_name: String.t(),
          session_status: session_status(),
          message_count: non_neg_integer()
        }

  @enforce_keys [:model_name, :session_status, :message_count]
  defstruct @enforce_keys
end
