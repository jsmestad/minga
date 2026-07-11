defmodule Minga.Frontend.Adapter.GUI.SplitSeparatorsEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
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
    writer =
      :gui_split_separators
      |> Writer.new()
      |> Writer.append(<<@op_gui_split_separators>>)
      |> Writer.rgb24(:border_color_rgb, model.border_color_rgb)
      |> Writer.uint8(:vertical_count, Enum.count(model.verticals))

    writer =
      Enum.reduce(model.verticals, writer, fn {col, start_row, end_row}, acc ->
        acc
        |> Writer.uint16(:vertical_col, col)
        |> Writer.uint16(:vertical_start_row, start_row)
        |> Writer.uint16(:vertical_end_row, end_row)
      end)

    writer = Writer.uint8(writer, :horizontal_count, Enum.count(model.horizontals))

    model.horizontals
    |> Enum.reduce(writer, fn {row, col, width, filename}, acc ->
      acc
      |> Writer.uint16(:horizontal_row, row)
      |> Writer.uint16(:horizontal_col, col)
      |> Writer.uint16(:horizontal_width, width)
      |> Writer.string16(:horizontal_filename, filename)
    end)
    |> Writer.finish()
  end
end
