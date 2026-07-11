defmodule Minga.Frontend.Adapter.GUI.ThemeEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.RenderModel.UI.Theme

  # gui_theme opcode
  @op_gui_theme 0x74

  @spec encode(Theme.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Theme{} = model, %Caches{} = caches) do
    fp = :erlang.phash2({model.name, model.color_slots})

    if fp != caches.last_theme_fp do
      cmd = encode_theme_binary(model.color_slots)
      {cmd, %{caches | last_theme_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_theme_binary([Theme.color_slot()]) :: binary()
  defp encode_theme_binary(color_slots) do
    writer =
      :gui_theme
      |> Writer.new()
      |> Writer.append(<<@op_gui_theme>>)
      |> Writer.uint8(:color_slot_count, Enum.count(color_slots))

    Enum.reduce(color_slots, writer, fn {slot, rgb}, acc ->
      acc
      |> Writer.uint8(:color_slot, slot)
      |> Writer.rgb24(:color_slot_rgb, rgb)
    end)
    |> Writer.finish()
  end
end
