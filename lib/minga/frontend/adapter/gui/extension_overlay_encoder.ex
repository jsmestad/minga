defmodule Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
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
    validate!(:entry_count, Enum.count(model.entries), Wire.max_u8())
    overlay_binaries = Enum.map(model.entries, &encode_entry/1)

    payload = IO.iodata_to_binary([<<Enum.count(overlay_binaries)::8>> | overlay_binaries])
    validate!(:payload_length, byte_size(payload), Wire.max_u16())
    <<@op_gui_extension_overlay, byte_size(payload)::16, payload::binary>>
  end

  @spec fingerprint(ExtensionOverlay.t()) :: term()
  defp fingerprint(%ExtensionOverlay{} = model), do: model.entries

  @spec encode_entry(Entry.t()) :: binary()
  defp encode_entry(%Entry{} = entry) do
    ext_name = encode_string8(to_string(entry.extension), :extension_length)
    oid = encode_string8(to_string(entry.overlay_id), :overlay_id_length)
    content = encode_string16(entry.content, :content_length)
    {r, g, b} = Wire.rgb(entry.fg)
    shape = overlay_shape_byte(entry.shape)

    validate!(:window_id, entry.window_id, Wire.max_u16())
    validate!(:row, entry.row, Wire.max_u16())
    validate!(:col, entry.col, Wire.max_u16())
    validate!(:opacity, entry.opacity, Wire.max_u8())

    <<ext_name::binary, oid::binary, entry.window_id::16, entry.row::16, entry.col::16, shape::8,
      r::8, g::8, b::8, entry.opacity::8, content::binary>>
  end

  @spec overlay_shape_byte(Entry.shape()) :: non_neg_integer()
  defp overlay_shape_byte(:cursor), do: 0
  defp overlay_shape_byte(:cursor_with_label), do: 1
  defp overlay_shape_byte(:label), do: 2
  defp overlay_shape_byte(:indicator), do: 3
  defp overlay_shape_byte(_shape), do: 3

  @spec encode_string8(iodata(), atom()) :: binary()
  defp encode_string8(value, field) do
    bytes = :erlang.iolist_to_binary([value])
    validate!(field, byte_size(bytes), Wire.max_u8())
    <<byte_size(bytes)::8, bytes::binary>>
  end

  @spec encode_string16(iodata(), atom()) :: binary()
  defp encode_string16(value, field) do
    bytes = :erlang.iolist_to_binary([value])
    validate!(field, byte_size(bytes), Wire.max_u16())
    <<byte_size(bytes)::16, bytes::binary>>
  end

  @spec validate!(atom(), term(), non_neg_integer()) :: :ok
  defp validate!(field, value, max),
    do: Wire.validate_uint!(:gui_extension_overlay, field, value, max)
end
