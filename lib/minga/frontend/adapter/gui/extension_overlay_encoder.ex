defmodule Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.ExtensionOverlay
  alias Minga.RenderModel.UI.ExtensionOverlay.Entry

  @op_gui_extension_overlay Opcodes.gui_extension_overlay()

  @spec encode(ExtensionOverlay.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%ExtensionOverlay{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_extension_overlay_fp do
      {encode_command(model), %{caches | last_extension_overlay_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(ExtensionOverlay.t()) :: binary()
  def encode_command(%ExtensionOverlay{} = model) do
    writer =
      :gui_extension_overlay
      |> Writer.new()
      |> Writer.uint8(:entry_count, Enum.count(model.entries))

    payload =
      model.entries
      |> Enum.reduce(writer, &encode_entry/2)
      |> Writer.finish()

    :gui_extension_overlay
    |> Writer.new()
    |> Writer.append(<<@op_gui_extension_overlay>>)
    |> Writer.payload16(:payload_length, payload)
    |> Writer.finish()
  end

  @spec fingerprint(ExtensionOverlay.t()) :: term()
  defp fingerprint(%ExtensionOverlay{} = model), do: model.entries

  @spec encode_entry(Entry.t(), Writer.t()) :: Writer.t()
  defp encode_entry(%Entry{} = entry, %Writer{} = writer) do
    writer
    |> Writer.string8(:extension_length, to_string(entry.extension))
    |> Writer.string8(:overlay_id_length, to_string(entry.overlay_id))
    |> Writer.uint16(:window_id, entry.window_id)
    |> Writer.uint16(:row, entry.row)
    |> Writer.uint16(:col, entry.col)
    |> Writer.uint8(:shape, overlay_shape_byte(entry.shape))
    |> Writer.rgb24(:fg, entry.fg)
    |> Writer.uint8(:opacity, entry.opacity)
    |> Writer.string16(:content_length, entry.content)
  end

  @spec overlay_shape_byte(Entry.shape()) :: non_neg_integer()
  defp overlay_shape_byte(:cursor), do: 0
  defp overlay_shape_byte(:cursor_with_label), do: 1
  defp overlay_shape_byte(:label), do: 2
  defp overlay_shape_byte(:indicator), do: 3
  defp overlay_shape_byte(_shape), do: 3
end
