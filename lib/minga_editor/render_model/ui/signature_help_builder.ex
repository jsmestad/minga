defmodule MingaEditor.RenderModel.UI.SignatureHelpBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.SignatureHelp
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @spec build(Context.t()) :: SignatureHelp.t()
  def build(%{shell_state: %{signature_help: sh}}) do
    fp = :erlang.phash2(sh)
    encoded = ProtocolGUI.encode_gui_signature_help(sh)

    %SignatureHelp{encoded: encoded, fingerprint: fp}
  end

  def build(_ctx) do
    fp = :erlang.phash2(nil)
    encoded = ProtocolGUI.encode_gui_signature_help(nil)

    %SignatureHelp{encoded: encoded, fingerprint: fp}
  end
end
