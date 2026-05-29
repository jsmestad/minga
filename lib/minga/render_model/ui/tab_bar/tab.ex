defmodule Minga.RenderModel.UI.TabBar.Tab do
  @moduledoc false

  @type kind :: :file | :agent
  @type agent_status :: :idle | :thinking | :tool_executing | :error | :plan | nil

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          workspace_id: non_neg_integer(),
          label: String.t(),
          icon: String.t(),
          dirty?: boolean(),
          kind: kind(),
          attention?: boolean(),
          agent_status: agent_status(),
          pinned?: boolean(),
          tint_color: non_neg_integer()
        }

  @enforce_keys [:id, :workspace_id, :label, :icon]
  defstruct id: 0,
            workspace_id: 0,
            label: "",
            icon: "",
            dirty?: false,
            kind: :file,
            attention?: false,
            agent_status: nil,
            pinned?: false,
            tint_color: 0
end
