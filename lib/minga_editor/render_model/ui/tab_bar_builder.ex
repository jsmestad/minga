defmodule MingaEditor.RenderModel.UI.TabBarBuilder do
  @moduledoc false

  alias Minga.Log
  alias Minga.RenderModel.UI.TabBar
  alias Minga.RenderModel.UI.TabBar.Tab
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.TabSummary
  alias MingaEditor.State.TabBar, as: TabBarState

  @spec build(Context.t()) :: TabBar.t()
  def build(%Context{} = ctx) do
    case shell_gui_payload(ctx) do
      {:board, _payload} ->
        %TabBar{}

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
  defp build_standard(%{shell_state: %{tab_bar: %TabBarState{}}} = ctx) do
    chrome_state = ChromeState.from_editor_state(ctx)

    %TabBar{
      visible?: true,
      active_tab_id: chrome_state.active_tab_id,
      tabs: Enum.map(chrome_state.visible_tabs, &tab_model/1)
    }
  end

  defp build_standard(_ctx), do: %TabBar{}

  @spec tab_model(TabSummary.t()) :: Tab.t()
  defp tab_model(%TabSummary{} = tab) do
    %Tab{
      id: tab.id,
      workspace_id: tab.workspace_id,
      label: tab.label,
      icon: tab.icon,
      dirty?: tab.dirty?,
      kind: tab.kind,
      attention?: tab.attention?,
      pinned?: tab.pinned?,
      tint_color: tab.tint_color
    }
  end

  @spec shell_gui_payload(Context.t()) :: term()
  defp shell_gui_payload(%{shell: shell} = ctx) do
    if function_exported?(shell, :gui_payload, 1) do
      shell.gui_payload(ctx)
    else
      nil
    end
  rescue
    _ -> nil
  end
end
