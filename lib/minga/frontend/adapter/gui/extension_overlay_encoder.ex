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
    {overlay_binaries, _remaining_budget} =
      Wire.bounded_entries(model.entries, &encode_entry/1, Wire.max_u8(), Wire.max_u16() - 1)

    payload = IO.iodata_to_binary([<<length(overlay_binaries)::8>> | overlay_binaries])
    <<@op_gui_extension_overlay, byte_size(payload)::16, payload::binary>>
  end

  @spec fingerprint(ExtensionOverlay.t()) :: term()
  defp fingerprint(%ExtensionOverlay{} = model), do: model.entries

  @spec encode_entry(Entry.t()) :: binary()
  defp encode_entry(%Entry{} = entry) do
    ext_name = Wire.utf8_prefix_bytes(to_string(entry.extension), Wire.max_u8())
    oid = Wire.utf8_prefix_bytes(to_string(entry.overlay_id), Wire.max_u8())
    content = Wire.utf8_prefix_bytes(entry.content, Wire.max_u16())
    {r, g, b} = Wire.rgb(entry.fg)
    shape = overlay_shape_byte(entry.shape)

    <<byte_size(ext_name)::8, ext_name::binary, byte_size(oid)::8, oid::binary,
      Wire.clamp_u16(entry.window_id)::16, Wire.clamp_u16(entry.row)::16,
      Wire.clamp_u16(entry.col)::16, shape::8, r::8, g::8, b::8, Wire.clamp_u8(entry.opacity)::8,
      byte_size(content)::16, content::binary>>
  end

  @spec overlay_shape_byte(Entry.shape()) :: non_neg_integer()
  defp overlay_shape_byte(:cursor), do: 0
  defp overlay_shape_byte(:cursor_with_label), do: 1
  defp overlay_shape_byte(:label), do: 2
  defp overlay_shape_byte(:indicator), do: 3
  defp overlay_shape_byte(_shape), do: 3
end
