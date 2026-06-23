defmodule Minga.RenderModel.UI.AgentContext do
  @moduledoc false

  alias __MODULE__.Progress
  alias __MODULE__.Todo

  @type status :: :idle | :working | :iterating | :needs_you | :done | :errored

  @type t :: %__MODULE__{
          visible: boolean(),
          task: String.t(),
          dispatch_timestamp: DateTime.t() | nil,
          status: status(),
          can_approve: boolean(),
          todos: [Todo.t()],
          progress: Progress.t()
        }

  @enforce_keys [:visible]
  defstruct visible: false,
            task: "",
            dispatch_timestamp: nil,
            status: :idle,
            can_approve: false,
            todos: [],
            progress: %Progress{}
end
