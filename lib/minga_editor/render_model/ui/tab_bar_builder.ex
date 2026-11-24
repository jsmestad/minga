defmodule MingaEditor.RenderModel.UI.TabBarBuilder do
  @moduledoc false

  alias Minga.Log
  alias Minga.RenderModel.UI.TabBar
  alias Minga.RenderModel.UI.TabBar.Tab
  alias MingaEditor.Agent.WorkspaceStatus
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.TabSummary
  alias MingaEditor.State.TabBar, as: TabBarState

  @spec build(Context.t()) :: TabBar.t()
  def build(%Context{} = ctx) do
    case shell_gui_payload(ctx) do
      nil ->
        build_standard(ctx)

      other ->
        Log.warning(
          :render,
          "Unsupported GUI shell payload #{inspect(other)}; using standard tabs"
        )

        build_standard(ctx)
    end
  end

  @spec build_standard(Context.t()) :: TabBar.t()
  defp build_standard(%Context{tab_bar: %TabBarState{}} = ctx) do
    chrome_state = ChromeState.from_editor_state(chrome_state_input(ctx))

    statuses = Map.new(chrome_state.workspaces, &{&1.id, &1.status})

    %TabBar{
      visible?: true,
      active_tab_id: chrome_state.active_tab_id,
      tabs: Enum.map(chrome_state.visible_tabs, &tab_model(&1, statuses))
    }
  end

  defp build_standard(_ctx), do: %TabBar{}

  # An Agent tab shows its workspace's status, including needs-you after a
  # failed start.
  @spec tab_model(TabSummary.t(), %{non_neg_integer() => Tab.agent_status()}) :: Tab.t()
  defp tab_model(%TabSummary{} = tab, statuses) do
    %Tab{
      agent_status: if(tab.kind == :agent, do: Map.get(statuses, tab.workspace_id)),
      id: tab.id,
      workspace_id: tab.workspace_id,
      label: tab.label,
      icon: tab.icon,
      dirty?: tab.dirty?,
      kind: tab.kind,
      attention?: tab.attention?,
      pinned?: tab.pinned?,
      ephemeral?: tab.ephemeral?,
      tint_color: tab.tint_color
    }
  end

  @spec shell_gui_payload(Context.t()) :: term()
  defp shell_gui_payload(%Context{} = ctx) do
    shell = ctx.intent.frame.shell

    if function_exported?(shell, :gui_payload, 1) do
      shell.gui_payload(ctx)
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp chrome_state_input(%Context{} = ctx) do
    %{
      tab_bar: ctx.tab_bar,
      agent: WorkspaceStatus.live_agent(ctx.intent.frame.shell_state),
      workspace: %{
        buffers: ctx.workspace.buffers,
        file_tree: ctx.workspace.file_tree,
        keymap_scope: ctx.workspace.keymap_scope,
        agent_ui: ctx.workspace.agent_ui
      }
    }
  end
end
