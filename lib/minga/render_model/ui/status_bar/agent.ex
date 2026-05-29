defmodule Minga.RenderModel.UI.StatusBar.Agent do
  @moduledoc false

  @type status :: :idle | :thinking | :tool_executing | :error | :plan | :inactive | nil

  @type t :: %__MODULE__{
          model_name: String.t(),
          message_count: non_neg_integer(),
          session_status: status(),
          agent_status: status(),
          background_count: non_neg_integer(),
          background_label: String.t() | nil,
          active_tool_name: String.t() | nil
        }

  defstruct model_name: "Agent",
            message_count: 0,
            session_status: nil,
            agent_status: nil,
            background_count: 0,
            background_label: nil,
            active_tool_name: nil
end
