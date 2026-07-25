defmodule MingaEditor.RenderModel.UI.WorkspacesBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Workspaces
  alias Minga.RenderModel.UI.Workspaces.VisibleTab
  alias Minga.RenderModel.UI.Workspaces.Workspace
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.TabSummary
  alias MingaEditor.Session.ChromeState.WorkspaceSummary
  alias MingaEditor.State.TabBar

  @spec build(map()) :: Workspaces.t()
  def build(%Context{tab_bar: %TabBar{}} = ctx) do
    chrome_state = ChromeState.from_editor_state(chrome_state_input(ctx))

    %Workspaces{
      visible?: true,
      active_workspace_id: chrome_state.active_workspace_id,
      mode: chrome_state.mode,
      attention_count: chrome_state.attention_count,
      workspaces: Enum.map(chrome_state.workspaces, &workspace_model/1),
      visible_tabs: Enum.map(chrome_state.visible_tabs, &visible_tab_model/1)
    }
  end

  def build(_ctx) do
    %Workspaces{}
  end

  @spec workspace_model(WorkspaceSummary.t()) :: Workspace.t()
  defp workspace_model(%WorkspaceSummary{} = workspace) do
    %Workspace{
      id: workspace.id,
      kind: workspace.kind,
      label: workspace.label,
      icon: workspace.icon,
      color: workspace.color,
      status: workspace.status,
      attention?: workspace.attention?,
      tab_count: workspace.tab_count,
      draft_count: workspace.draft_count,
      conflict_count: workspace.conflict_count,
      running_background_count: workspace.running_background_count,
      closeable?: workspace.closeable?
    }
  end

  @spec visible_tab_model(TabSummary.t()) :: VisibleTab.t()
  defp visible_tab_model(%TabSummary{} = tab) do
    %VisibleTab{
      id: tab.id,
      workspace_id: tab.workspace_id,
      kind: tab.kind,
      label: tab.label,
      path: tab.path,
      icon: tab.icon,
      dirty?: tab.dirty?,
      draft_state: tab.draft_state,
      attention?: tab.attention?,
      pinned?: tab.pinned?,
      ephemeral?: tab.ephemeral?,
      tint_color: tab.tint_color
    }
  end

  defp chrome_state_input(%Context{} = ctx) do
    %{
      tab_bar: ctx.tab_bar,
      workspace: %{
        buffers: ctx.workspace.buffers,
        file_tree: ctx.workspace.file_tree,
        keymap_scope: ctx.workspace.keymap_scope
      }
    }
  end
end
