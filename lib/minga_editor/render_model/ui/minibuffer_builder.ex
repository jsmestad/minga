defmodule MingaEditor.RenderModel.UI.MinibufferBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Minibuffer
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.MinibufferData

  @spec build(MinibufferData.t() | nil) :: Minibuffer.t()
  def build(%MinibufferData{} = data) do
    fingerprint = minibuffer_fingerprint(data)
    encoded = ProtocolGUI.encode_gui_minibuffer(data)

    %Minibuffer{encoded: encoded, fingerprint: fingerprint}
  end

  def build(nil) do
    encoded = ProtocolGUI.encode_gui_minibuffer(%MinibufferData{visible: false})

    %Minibuffer{encoded: encoded, fingerprint: :hidden}
  end

  @spec minibuffer_fingerprint(MinibufferData.t()) :: term()
  defp minibuffer_fingerprint(%MinibufferData{visible: false}), do: :hidden

  defp minibuffer_fingerprint(%MinibufferData{} = d) do
    {d.visible, d.mode, d.cursor_pos, d.prompt, d.input, d.context, d.selected_index,
     length(d.candidates), d.total_candidates,
     Enum.map(d.candidates, fn c ->
       {c.label, c.description, c.match_score, Map.get(c, :annotation, ""),
        Map.get(c, :match_positions, [])}
     end)}
  end
end
