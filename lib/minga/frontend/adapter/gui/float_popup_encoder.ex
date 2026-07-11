defmodule Minga.Frontend.Adapter.GUI.FloatPopupEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
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
    writer =
      :gui_float_popup
      |> Writer.new()
      |> Writer.append(<<@op_gui_float_popup, 1::8>>)
      |> Writer.uint16(:width, model.width)
      |> Writer.uint16(:height, model.height)
      |> Writer.string16(:title, model.title)
      |> Writer.uint16(:line_count, Enum.count(model.lines))

    model.lines
    |> Enum.reduce(writer, &Writer.string16(&2, :line, &1))
    |> Writer.finish()
  end

  @spec fingerprint(FloatPopup.t()) :: term()
  defp fingerprint(%FloatPopup{visible?: false}), do: :hidden

  defp fingerprint(%FloatPopup{} = model) do
    {model.visible?, model.title, model.lines, model.width, model.height}
  end
end
