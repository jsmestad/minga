defmodule MingaEditor.RenderModel.UI.WorkspacesBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Workspaces
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.State.TabBar

  @spec build(map()) :: Workspaces.t()
  def build(%{shell_state: %{tab_bar: %TabBar{}}} = ctx) do
    chrome_state = ChromeState.from_editor_state(ctx)
    fp = workspaces_fingerprint(chrome_state)
    encoded = ProtocolGUI.encode_gui_workspaces(chrome_state)

    %Workspaces{encoded: encoded, fingerprint: fp}
  end

  def build(_ctx) do
    %Workspaces{encoded: nil, fingerprint: :suppressed}
  end

  @spec workspaces_fingerprint(ChromeState.t()) :: integer()
  defp workspaces_fingerprint(%ChromeState{} = chrome_state) do
    :erlang.phash2({
      chrome_state.active_workspace_id,
      chrome_state.background_count,
      chrome_state.attention_count,
      chrome_state.draft_count,
      chrome_state.conflict_count,
      chrome_state.mode,
      chrome_state.visible_tabs,
      chrome_state.workspaces
    })
  end
end
