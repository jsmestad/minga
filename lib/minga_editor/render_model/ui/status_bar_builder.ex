defmodule MingaEditor.RenderModel.UI.StatusBarBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.StatusBar
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.StatusBar.Data, as: StatusBarData

  @spec build(StatusBarData.t(), term(), term()) :: StatusBar.t()
  def build(status_bar_data, theme, ctx) do
    status_bar_data = StatusBarData.with_modeline_segments(status_bar_data, theme)
    chrome_state = ChromeState.from_editor_state(ctx)
    encoded = ProtocolGUI.encode_gui_status_bar(status_bar_data, chrome_state)

    %StatusBar{encoded: encoded}
  end
end
