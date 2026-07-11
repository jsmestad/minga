defmodule Minga.Frontend.Adapter.GUI.GutterSeparatorEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.GutterSeparator

  @op_gui_gutter_sep Opcodes.gui_gutter_sep()

  @spec encode(GutterSeparator.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%GutterSeparator{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_gutter_separator_fp do
      {encode_binary(model), %{caches | last_gutter_separator_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_binary(GutterSeparator.t()) :: binary()
  defp encode_binary(%GutterSeparator{col: col, color_rgb: rgb}) do
    :gui_gutter_separator
    |> Writer.new()
    |> Writer.append(<<@op_gui_gutter_sep>>)
    |> Writer.uint16(:col, col)
    |> Writer.rgb24(:color_rgb, rgb)
    |> Writer.finish()
  end
end
