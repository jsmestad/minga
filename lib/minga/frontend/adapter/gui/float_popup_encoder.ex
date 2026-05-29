defmodule Minga.Frontend.Adapter.GUI.FloatPopupEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.FloatPopup

  @op_gui_float_popup Opcodes.gui_float_popup()

  @spec encode(FloatPopup.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%FloatPopup{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_float_popup_fp do
      {encode_command(model), %{caches | last_float_popup_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(FloatPopup.t()) :: binary()
  def encode_command(%FloatPopup{visible?: false}), do: <<@op_gui_float_popup, 0::8>>

  def encode_command(%FloatPopup{} = model) do
    title_bytes = IO.iodata_to_binary(model.title)

    line_data =
      Enum.map(model.lines, fn line ->
        text = IO.iodata_to_binary(line)
        <<byte_size(text)::16, text::binary>>
      end)

    IO.iodata_to_binary([
      <<@op_gui_float_popup, 1::8, model.width::16, model.height::16, byte_size(title_bytes)::16,
        title_bytes::binary, length(model.lines)::16>>
      | line_data
    ])
  end

  @spec fingerprint(FloatPopup.t()) :: term()
  defp fingerprint(%FloatPopup{visible?: false}), do: :hidden

  defp fingerprint(%FloatPopup{} = model) do
    {model.visible?, model.title, model.lines, model.width, model.height}
  end
end
