defmodule Minga.RenderModel.UI.AgentContext do
  @moduledoc false

  @type status :: :idle | :working | :iterating | :needs_you | :done | :errored

  @type t :: %__MODULE__{
          visible: boolean(),
          task: String.t(),
          dispatch_timestamp: DateTime.t(),
          status: status(),
          can_approve: boolean()
        }

  @enforce_keys [:visible]
  defstruct visible: false,
            task: "",
            dispatch_timestamp: nil,
            status: :idle,
            can_approve: false
end
