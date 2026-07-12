defmodule MingaEditor.RenderPipeline.WorkspaceIntent do
  @moduledoc "Explicit allowlisted workspace portion of an Editor-to-Renderer intent."

  @fields [
    :buffers,
    :viewport,
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
          viewport: term(),
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

  @doc "Copies only reviewed workspace rendering fields; windows are a separate typed carrier."
  @spec from_workspace(MingaEditor.RenderPipeline.Input.workspace()) :: t()
  def from_workspace(workspace) when is_map(workspace) do
    %__MODULE__{
      buffers: Map.get(workspace, :buffers),
      viewport: Map.get(workspace, :viewport),
      file_tree: Map.get(workspace, :file_tree),
      agent_ui: Map.get(workspace, :agent_ui),
      editing: Map.get(workspace, :editing),
      document_highlights: Map.get(workspace, :document_highlights),
      cmd_hover_link: Map.get(workspace, :cmd_hover_link),
      mouse: Map.get(workspace, :mouse),
      search: Map.get(workspace, :search),
      keymap_scope: Map.get(workspace, :keymap_scope, :editor),
      launchpad: Map.get(workspace, :launchpad)
    }
  end
end
