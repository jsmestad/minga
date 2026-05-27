defmodule MingaEditor.RenderModel.UI.TabBarBuilder do
  @moduledoc false

  alias Minga.Log
  alias Minga.RenderModel.UI.TabBar
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Frontend.Protocol.GUI.BoardPayload
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.State.TabBar, as: TabBarState

  @spec build(Context.t()) :: TabBar.t()
  def build(%Context{} = ctx) do
    case shell_gui_payload(ctx) do
      {:board, %BoardPayload{}} ->
        %TabBar{encoded: nil, fingerprint: :suppressed}

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

    fp =
      :erlang.phash2({
        chrome_state.active_workspace_id,
        chrome_state.active_tab_id,
        chrome_state.visible_tabs
      })

    encoded = ProtocolGUI.encode_gui_tab_bar(chrome_state)

    %TabBar{encoded: encoded, fingerprint: fp}
  end

  defp build_standard(_ctx) do
    %TabBar{encoded: nil, fingerprint: :suppressed}
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
