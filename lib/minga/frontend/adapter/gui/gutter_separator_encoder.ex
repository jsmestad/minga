defmodule Minga.Frontend.Adapter.GUI.GutterSeparatorEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
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
    <<@op_gui_gutter_sep, col::16, red(rgb)::8, green(rgb)::8, blue(rgb)::8>>
  end

  @spec red(non_neg_integer()) :: non_neg_integer()
  defp red(rgb), do: rgb >>> 16 &&& 0xFF

  @spec green(non_neg_integer()) :: non_neg_integer()
  defp green(rgb), do: rgb >>> 8 &&& 0xFF

  @spec blue(non_neg_integer()) :: non_neg_integer()
  defp blue(rgb), do: rgb &&& 0xFF
end
