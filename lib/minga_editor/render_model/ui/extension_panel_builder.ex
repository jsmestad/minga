defmodule MingaEditor.RenderModel.UI.ExtensionPanelBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.ExtensionPanel
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @spec build() :: ExtensionPanel.t()
  def build do
    panels = Minga.Extension.Panel.visible()
    fp = :erlang.phash2(panels)
    encoded = ProtocolGUI.encode_gui_extension_panels(panels)

    %ExtensionPanel{encoded: encoded, fingerprint: fp}
  end
end
