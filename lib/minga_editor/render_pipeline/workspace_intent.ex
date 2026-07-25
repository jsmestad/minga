defmodule MingaEditor.RenderPipeline.WorkspaceIntent do
  @moduledoc "Explicit allowlisted workspace portion of an Editor-to-Renderer intent."

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Session.State, as: SessionState

  @fields [
    :buffers,
    :file_tree,
    :agent_ui,
    :editing,
    :document_highlights,
    :cmd_hover_link,
    :mouse,
    :search,
    :keymap_scope,
    :launchpad
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          buffers: term(),
          file_tree: term(),
          agent_ui: term(),
          editing: term(),
          document_highlights: term(),
          cmd_hover_link: term(),
          mouse: term(),
          search: term(),
          keymap_scope: atom(),
          launchpad: term()
        }

  @spec from_workspace(SessionState.t()) :: t()
  def from_workspace(%SessionState{} = workspace) do
    %__MODULE__{
      buffers: workspace.buffers,
      file_tree: SessionState.file_tree_state(workspace),
      agent_ui: workspace.agent_ui,
      editing: workspace.editing,
      document_highlights: workspace.document_highlights,
      cmd_hover_link: workspace.hover_observation.link,
      mouse: workspace.mouse,
      search: workspace.search,
      keymap_scope: workspace.keymap_scope,
      launchpad: workspace.launchpad
    }
  end

  @spec record_agent_scroll_metrics(t(), non_neg_integer(), pos_integer()) :: t()
  def record_agent_scroll_metrics(
        %__MODULE__{agent_ui: agent_ui} = workspace,
        total_lines,
        visible_height
      ) do
    struct!(workspace,
      agent_ui: UIState.record_scroll_metrics(agent_ui, total_lines, visible_height)
    )
  end
end
