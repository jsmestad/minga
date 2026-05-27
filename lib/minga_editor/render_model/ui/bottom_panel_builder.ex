defmodule MingaEditor.RenderModel.UI.BottomPanelBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.BottomPanel
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @doc """
  Builds the bottom panel model.

  Returns `{model, updated_message_store}` because encoding may advance the
  message_store cursor when new message entries have arrived. The caller must
  apply the updated message_store back to ctx.
  """
  @spec build(Context.t()) :: {BottomPanel.t(), term()}
  def build(%{shell_state: %{bottom_panel: panel}, message_store: store} = _ctx) do
    fp = :erlang.phash2({panel, store})
    {cmd, new_store} = ProtocolGUI.encode_gui_bottom_panel(panel, store)

    {%BottomPanel{encoded: cmd, fingerprint: fp}, new_store}
  end

  def build(%{message_store: store}) do
    # No bottom_panel in shell_state; produce a hidden panel
    hidden_panel = %MingaEditor.BottomPanel{}
    fp = :erlang.phash2({hidden_panel, store})
    {cmd, new_store} = ProtocolGUI.encode_gui_bottom_panel(hidden_panel, store)

    {%BottomPanel{encoded: cmd, fingerprint: fp}, new_store}
  end

  def build(_ctx) do
    # No message_store at all; produce a hidden panel with no side effect
    hidden_panel = %{visible: false}
    store = nil
    fp = :erlang.phash2({hidden_panel, store})

    {%BottomPanel{encoded: <<0x7C, 0>>, fingerprint: fp}, nil}
  end
end
