defmodule MingaEditor.RenderModel.UI.HoverPopupBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.HoverPopup
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @spec build(Context.t()) :: HoverPopup.t()
  def build(%Context{shell_state: %{hover_popup: popup}}) do
    fp = :erlang.phash2(popup)
    encoded = ProtocolGUI.encode_gui_hover_popup(popup)

    %HoverPopup{encoded: encoded, fingerprint: fp}
  end

  def build(%Context{}) do
    fp = :erlang.phash2(nil)
    encoded = ProtocolGUI.encode_gui_hover_popup(nil)

    %HoverPopup{encoded: encoded, fingerprint: fp}
  end
end
