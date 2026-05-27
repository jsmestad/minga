defmodule MingaEditor.RenderModel.UI.ObservatoryBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Observatory
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Observatory.Data, as: ObservatoryData

  @spec build(map()) :: Observatory.t()
  def build(%{observatory_visible: true, observatory_data: data}) do
    payload = data || ObservatoryData.visible(nil, [])
    fp = :erlang.phash2(payload)
    encoded = ProtocolGUI.encode_gui_observatory(payload)

    %Observatory{visible: true, encoded: encoded, fingerprint: fp}
  end

  def build(_shell_state) do
    encoded = ProtocolGUI.encode_gui_observatory(ObservatoryData.hidden())

    %Observatory{visible: false, encoded: encoded, fingerprint: :hidden}
  end
end
