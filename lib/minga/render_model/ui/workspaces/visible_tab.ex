defmodule Minga.RenderModel.UI.Workspaces.VisibleTab do
  @moduledoc false

  @type kind :: :file
  @type draft_state :: :none | :draft | :draft_elsewhere | :conflict

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          workspace_id: non_neg_integer(),
          kind: kind(),
          label: String.t(),
          path: String.t() | nil,
          icon: String.t(),
          dirty?: boolean(),
          draft_state: draft_state(),
          attention?: boolean(),
          pinned?: boolean(),
          tint_color: non_neg_integer()
        }

  @enforce_keys [:id, :workspace_id, :label, :icon]
  defstruct id: 0,
            workspace_id: 0,
            kind: :file,
            label: "",
            path: nil,
            icon: "",
            dirty?: false,
            draft_state: :none,
            attention?: false,
            pinned?: false,
            tint_color: 0
end
