defmodule Minga.Frontend.Adapter.GUI.SplitSeparatorsEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.SplitSeparators

  @op_gui_split_separators Opcodes.gui_split_separators()

  @spec encode(SplitSeparators.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%SplitSeparators{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_split_separators_fp do
      {encode_binary(model), %{caches | last_split_separators_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_binary(SplitSeparators.t()) :: binary()
  defp encode_binary(%SplitSeparators{} = model) do
    verticals =
      Enum.map(model.verticals, fn {col, start_row, end_row} ->
        <<col::16, start_row::16, end_row::16>>
      end)

    horizontals =
      Enum.map(model.horizontals, fn {row, col, width, filename} ->
        name = IO.iodata_to_binary(filename)
        <<row::16, col::16, width::16, byte_size(name)::16, name::binary>>
      end)

    IO.iodata_to_binary([
      <<@op_gui_split_separators, red(model.border_color_rgb)::8,
        green(model.border_color_rgb)::8, blue(model.border_color_rgb)::8,
        length(model.verticals)::8>>,
      verticals,
      <<length(model.horizontals)::8>>,
      horizontals
    ])
  end

  @spec red(non_neg_integer()) :: non_neg_integer()
  defp red(rgb), do: rgb >>> 16 &&& 0xFF

  @spec green(non_neg_integer()) :: non_neg_integer()
  defp green(rgb), do: rgb >>> 8 &&& 0xFF

  @spec blue(non_neg_integer()) :: non_neg_integer()
  defp blue(rgb), do: rgb &&& 0xFF
end
