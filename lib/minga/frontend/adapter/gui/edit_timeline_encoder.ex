defmodule Minga.Frontend.Adapter.GUI.EditTimelineEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.EditTimeline

  @op_gui_edit_timeline Opcodes.gui_edit_timeline()
  @max_u8 255

  @spec encode(EditTimeline.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%EditTimeline{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_edit_timeline_fp do
      {encode_binary(model), %{caches | last_edit_timeline_fp: fp}}
    else
      {nil, caches}
    end
  end

  # Wire format: opcode + len(2) + payload
  #   payload: visible(1) + viewing_index(2) + count(1) + entries...
  #   entry: index(1) + tool_name_len(1) + tool_name + timestamp_delta(4)
  # viewing_index of 0xFFFF means "live at latest" (nil).
  @spec encode_binary(EditTimeline.t()) :: binary()
  defp encode_binary(%EditTimeline{} = model) do
    visible_byte = if model.visible?, do: 1, else: 0

    viewing_u16 =
      if model.viewing_index == nil, do: 0xFFFF, else: min(model.viewing_index, 0xFFFE)

    count = min(length(model.entries), @max_u8)

    entry_binaries =
      model.entries
      |> Enum.take(@max_u8)
      |> Enum.map(fn entry ->
        tool_name_bytes = :erlang.iolist_to_binary([entry.tool_name])
        tool_name_len = min(byte_size(tool_name_bytes), @max_u8)
        truncated_name = binary_part(tool_name_bytes, 0, tool_name_len)

        <<entry.index::8, tool_name_len::8, truncated_name::binary, entry.timestamp_delta::32>>
      end)

    payload =
      IO.iodata_to_binary([<<visible_byte::8, viewing_u16::16, count::8>> | entry_binaries])

    <<@op_gui_edit_timeline, byte_size(payload)::16, payload::binary>>
  end
end
