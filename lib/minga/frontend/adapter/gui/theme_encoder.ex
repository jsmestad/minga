defmodule Minga.Frontend.Adapter.GUI.ThemeEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
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
    count = length(color_slots)

    entries =
      Enum.map(color_slots, fn {slot, rgb} ->
        r = bsr(band(rgb, 0xFF0000), 16)
        g = bsr(band(rgb, 0x00FF00), 8)
        b = band(rgb, 0x0000FF)
        <<slot::8, r::8, g::8, b::8>>
      end)

    IO.iodata_to_binary([@op_gui_theme, <<count::8>> | entries])
  end
end
