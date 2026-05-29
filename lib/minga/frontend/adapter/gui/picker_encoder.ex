defmodule Minga.Frontend.Adapter.GUI.PickerEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Picker
  alias Minga.RenderModel.UI.Picker.ActionMenu
  alias Minga.RenderModel.UI.Picker.Item

  @op_gui_picker Opcodes.gui_picker()
  @op_gui_picker_preview Opcodes.gui_picker_preview()
  @section_picker_header 0x01
  @section_picker_query 0x02
  @section_picker_items 0x03
  @section_picker_action_menu 0x04
  @section_picker_mode_prefix 0x05
  @section_picker_load_status 0x06

  @spec encode(Picker.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Picker{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_picker_fp do
      {encode_command(model), %{caches | last_picker_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(Picker.t()) :: binary()
  def encode_command(%Picker{visible?: false}) do
    IO.iodata_to_binary([encode_picker_hidden(), encode_preview(nil)])
  end

  def encode_command(%Picker{} = model) do
    IO.iodata_to_binary([encode_picker(model), encode_preview(model.preview_lines)])
  end

  @spec fingerprint(Picker.t()) :: integer() | :closed
  defp fingerprint(%Picker{visible?: false}), do: :closed

  defp fingerprint(%Picker{} = model) do
    :erlang.phash2({
      model.title,
      model.query,
      model.mode_prefix,
      model.selected_index,
      model.filtered_count,
      model.total_count,
      model.marked_count,
      model.has_preview?,
      model.items,
      model.action_menu,
      model.load_status,
      model.preview_lines
    })
  end

  @spec encode_picker_hidden() :: binary()
  defp encode_picker_hidden, do: <<@op_gui_picker, 0::8>>

  @spec encode_picker(Picker.t()) :: binary()
  defp encode_picker(%Picker{} = model) do
    title_bytes = :erlang.iolist_to_binary([model.title])
    query_bytes = :erlang.iolist_to_binary([model.query])
    mode_prefix_bytes = :erlang.iolist_to_binary([model.mode_prefix])
    has_preview_byte = if model.has_preview?, do: 1, else: 0
    entries = Enum.map(model.items, &encode_item/1)
    items_payload = IO.iodata_to_binary([<<length(model.items)::16>> | entries])

    sections = [
      Wire.encode_section(
        @section_picker_header,
        <<1::8, model.selected_index::16, model.filtered_count::16, model.total_count::16,
          has_preview_byte::8, byte_size(title_bytes)::16, title_bytes::binary,
          model.marked_count::16>>
      ),
      Wire.encode_section(
        @section_picker_query,
        <<byte_size(query_bytes)::16, query_bytes::binary>>
      ),
      Wire.encode_section(@section_picker_items, items_payload),
      Wire.encode_section(@section_picker_action_menu, encode_action_menu(model.action_menu)),
      Wire.encode_section(
        @section_picker_mode_prefix,
        <<byte_size(mode_prefix_bytes)::16, mode_prefix_bytes::binary>>
      ),
      Wire.encode_section(@section_picker_load_status, encode_load_status(model.load_status))
    ]

    IO.iodata_to_binary([<<@op_gui_picker, length(sections)::8>> | sections])
  end

  @spec encode_item(Item.t()) :: binary()
  defp encode_item(%Item{} = item) do
    label_bytes = :erlang.iolist_to_binary([item.label])
    desc_bytes = :erlang.iolist_to_binary([item.description || ""])
    annotation_bytes = :erlang.iolist_to_binary([item.annotation || ""])
    icon_color = item.icon_color || 0
    flags = encode_item_flags(item)
    positions = item.match_positions
    pos_count = min(length(positions), 255)

    pos_bytes =
      positions |> Enum.take(pos_count) |> Enum.map(&<<&1::16>>) |> IO.iodata_to_binary()

    <<icon_color::24, flags::8, byte_size(label_bytes)::16, label_bytes::binary,
      byte_size(desc_bytes)::16, desc_bytes::binary, byte_size(annotation_bytes)::16,
      annotation_bytes::binary, pos_count::8, pos_bytes::binary>>
  end

  @spec encode_item_flags(Item.t()) :: non_neg_integer()
  defp encode_item_flags(%Item{} = item) do
    two_line = if item.two_line?, do: 1, else: 0
    marked = if item.marked?, do: 1, else: 0
    bor(two_line, marked <<< 1)
  end

  @spec encode_action_menu(ActionMenu.t() | nil) :: binary()
  defp encode_action_menu(nil), do: <<0::8>>

  defp encode_action_menu(%ActionMenu{} = menu) do
    action_bins =
      Enum.map(menu.actions, fn name ->
        name_bytes = :erlang.iolist_to_binary([name])
        <<byte_size(name_bytes)::16, name_bytes::binary>>
      end)

    IO.iodata_to_binary([<<1::8, menu.selected_index::8, length(menu.actions)::8>>, action_bins])
  end

  @spec encode_load_status(Picker.load_status()) :: binary()
  defp encode_load_status(:ready), do: <<0::8>>
  defp encode_load_status(:loading), do: <<1::8>>

  defp encode_load_status({:error, reason}) do
    <<2::8, byte_size(reason)::16, reason::binary>>
  end

  @spec encode_preview([[Picker.preview_segment()]] | nil) :: binary()
  defp encode_preview(nil), do: <<@op_gui_picker_preview, 0::8>>

  defp encode_preview(lines) when is_list(lines) do
    line_binaries = Enum.map(lines, &encode_preview_line/1)
    IO.iodata_to_binary([@op_gui_picker_preview, <<1::8, length(lines)::16>> | line_binaries])
  end

  @spec encode_preview_line([Picker.preview_segment()]) :: iodata()
  defp encode_preview_line(segments) do
    seg_bins = Enum.map(segments, &encode_preview_segment/1)
    [<<length(segments)::8>> | seg_bins]
  end

  @spec encode_preview_segment(Picker.preview_segment()) :: binary()
  defp encode_preview_segment({text, fg_color, bold}) do
    text_bytes = :erlang.iolist_to_binary([text])
    flags = if bold, do: 1, else: 0
    <<fg_color::24, flags::8, byte_size(text_bytes)::16, text_bytes::binary>>
  end
end
