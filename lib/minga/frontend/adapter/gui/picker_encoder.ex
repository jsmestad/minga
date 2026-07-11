defmodule Minga.Frontend.Adapter.GUI.PickerEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Encode
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Picker
  alias Minga.RenderModel.UI.Picker.ActionMenu

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

  # Each section body delegates to the schema-generated pure encoder. The builder
  # has already normalized the model into wire-shaped maps, so each projection is
  # a plain key rename with no derivation.
  @spec encode_picker(Picker.t()) :: binary()
  defp encode_picker(%Picker{} = model) do
    :gui_picker
    |> Writer.new()
    |> preflight_picker(model)
    |> Writer.append(<<@op_gui_picker>>)
    |> Writer.uint8(:section_count, 6)
    |> Writer.section16(
      :picker_header,
      @section_picker_header,
      Encode.encode_gui_picker_header(to_wire_header(model))
    )
    |> Writer.section16(
      :picker_query,
      @section_picker_query,
      Encode.encode_gui_picker_query(%{text: model.query})
    )
    |> Writer.section16(
      :picker_items,
      @section_picker_items,
      Encode.encode_gui_picker_items(model.items)
    )
    |> Writer.section16(
      :picker_action_menu,
      @section_picker_action_menu,
      Encode.encode_gui_picker_action_menu(to_wire_action_menu(model.action_menu))
    )
    |> Writer.section16(
      :picker_mode_prefix,
      @section_picker_mode_prefix,
      Encode.encode_gui_picker_mode_prefix(%{text: model.mode_prefix})
    )
    |> Writer.section16(
      :picker_load_status,
      @section_picker_load_status,
      Encode.encode_gui_picker_load_status(to_wire_load_status(model.load_status))
    )
    |> Writer.finish()
  end

  @spec preflight_picker(Writer.t(), Picker.t()) :: Writer.t()
  defp preflight_picker(%Writer{} = writer, %Picker{} = model) do
    writer
    |> Writer.check_uint8(:visible, 1)
    |> Writer.check_uint16(:selected_index, model.selected_index)
    |> Writer.check_uint16(:filtered_count, model.filtered_count)
    |> Writer.check_uint16(:total_count, model.total_count)
    |> Writer.check_uint8(:has_preview, if(model.has_preview?, do: 1, else: 0))
    |> Writer.check_string16(:title, model.title)
    |> Writer.check_uint16(:marked_count, model.marked_count)
    |> Writer.check_string16(:query, model.query)
    |> Writer.check_uint16(:item_count, Enum.count(model.items))
    |> preflight_items(model.items)
    |> preflight_action_menu(model.action_menu)
    |> Writer.check_string16(:mode_prefix, model.mode_prefix)
    |> preflight_load_status(model.load_status)
  end

  @spec preflight_items(Writer.t(), [Picker.item()]) :: Writer.t()
  defp preflight_items(%Writer{} = writer, items) do
    Enum.reduce(items, writer, &preflight_item/2)
  end

  @spec preflight_item(Picker.item(), Writer.t()) :: Writer.t()
  defp preflight_item(item, %Writer{} = writer) do
    writer
    |> Writer.check_uint24(:item_icon_color, item.icon_color)
    |> Writer.check_uint8(:item_flags, item.flags)
    |> Writer.check_string16(:item_label, item.label)
    |> Writer.check_string16(:item_description, item.description)
    |> Writer.check_string16(:item_annotation, item.annotation)
    |> Writer.check_uint8(:item_match_position_count, Enum.count(item.match_positions))
    |> preflight_match_positions(item.match_positions)
  end

  @spec preflight_match_positions(Writer.t(), [non_neg_integer()]) :: Writer.t()
  defp preflight_match_positions(%Writer{} = writer, positions) do
    Enum.reduce(positions, writer, fn position, acc ->
      Writer.check_uint16(acc, :item_match_position, position)
    end)
  end

  @spec preflight_action_menu(Writer.t(), ActionMenu.t() | nil) :: Writer.t()
  defp preflight_action_menu(%Writer{} = writer, nil) do
    Writer.check_uint8(writer, :action_menu_visible, 0)
  end

  defp preflight_action_menu(%Writer{} = writer, %ActionMenu{} = menu) do
    writer
    |> Writer.check_uint8(:action_menu_visible, 1)
    |> Writer.check_uint8(:action_menu_selected_index, menu.selected_index)
    |> Writer.check_uint8(:action_count, Enum.count(menu.actions))
    |> preflight_actions(menu.actions)
  end

  @spec preflight_actions(Writer.t(), [String.t()]) :: Writer.t()
  defp preflight_actions(%Writer{} = writer, actions) do
    Enum.reduce(actions, writer, fn action, acc ->
      Writer.check_string16(acc, :action_name, action)
    end)
  end

  @spec preflight_load_status(Writer.t(), Picker.load_status()) :: Writer.t()
  defp preflight_load_status(%Writer{} = writer, :ready) do
    Writer.check_uint8(writer, :load_status, 0)
  end

  defp preflight_load_status(%Writer{} = writer, :loading) do
    Writer.check_uint8(writer, :load_status, 1)
  end

  defp preflight_load_status(%Writer{} = writer, {:error, reason}) do
    writer
    |> Writer.check_uint8(:load_status, 2)
    |> Writer.check_string16(:load_status_message, reason)
  end

  @spec to_wire_header(Picker.t()) :: map()
  defp to_wire_header(%Picker{} = model) do
    %{
      visible: 1,
      selected_index: model.selected_index,
      filtered_count: model.filtered_count,
      total_count: model.total_count,
      has_preview: if(model.has_preview?, do: 1, else: 0),
      title: model.title,
      marked_count: model.marked_count
    }
  end

  @spec to_wire_action_menu(ActionMenu.t() | nil) :: map()
  defp to_wire_action_menu(nil), do: %{visible: 0}

  defp to_wire_action_menu(%ActionMenu{} = menu) do
    %{visible: 1, selected_index: menu.selected_index, actions: menu.actions}
  end

  @spec to_wire_load_status(Picker.load_status()) :: map()
  defp to_wire_load_status(:ready), do: %{status: 0}
  defp to_wire_load_status(:loading), do: %{status: 1}
  defp to_wire_load_status({:error, reason}), do: %{status: 2, message: reason}

  @spec encode_preview([[Picker.preview_segment()]] | nil) :: binary()
  defp encode_preview(nil), do: <<@op_gui_picker_preview, 0::8>>

  defp encode_preview(lines) when is_list(lines) do
    writer =
      :gui_picker_preview
      |> Writer.new()
      |> Writer.append(<<@op_gui_picker_preview, 1::8>>)
      |> Writer.uint16(:line_count, Enum.count(lines))

    lines
    |> Enum.reduce(writer, &encode_preview_line/2)
    |> Writer.finish()
  end

  @spec encode_preview_line([Picker.preview_segment()], Writer.t()) :: Writer.t()
  defp encode_preview_line(segments, %Writer{} = writer) do
    writer = Writer.uint8(writer, :segment_count, Enum.count(segments))
    Enum.reduce(segments, writer, &encode_preview_segment/2)
  end

  @spec encode_preview_segment(Picker.preview_segment(), Writer.t()) :: Writer.t()
  defp encode_preview_segment({text, fg_color, bold}, %Writer{} = writer) do
    flags = if bold, do: 1, else: 0

    writer
    |> Writer.rgb24(:segment_fg_color, fg_color)
    |> Writer.uint8(:segment_flags, flags)
    |> Writer.string16(:segment_text, text)
  end
end
