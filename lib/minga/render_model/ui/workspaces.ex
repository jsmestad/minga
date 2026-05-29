defmodule Minga.RenderModel.UI.Workspaces do
  @moduledoc """
  Semantic workspace chrome model for GUI adapters.

  The model carries workspace and visible-tab facts. The GUI adapter owns payload budgeting, protocol flags, and cache fingerprints.
  """

  alias Minga.RenderModel.UI.Workspaces.VisibleTab
  alias Minga.RenderModel.UI.Workspaces.Workspace

  @type mode :: :editor | :agent | :file_tree | :other

  @type t :: %__MODULE__{
          visible?: boolean(),
          active_workspace_id: non_neg_integer(),
          mode: mode(),
          attention_count: non_neg_integer(),
          workspaces: [Workspace.t()],
          visible_tabs: [VisibleTab.t()]
        }

  defstruct visible?: false,
            active_workspace_id: 0,
            mode: :editor,
            attention_count: 0,
            workspaces: [],
            visible_tabs: []
end
