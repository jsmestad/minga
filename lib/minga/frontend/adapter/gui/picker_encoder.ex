defmodule Minga.Frontend.Adapter.GUI.PickerEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
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

  # The hidden/visible dispatch and the Wire.encode_section framing stay
  # hand-written here; each section body delegates to the schema-generated pure
  # encoder. The builder has already normalized the model into wire-shaped maps,
  # so each `to_wire_*` projection is a plain key rename with no derivation.
  @spec encode_picker(Picker.t()) :: binary()
  defp encode_picker(%Picker{} = model) do
    sections = [
      Wire.encode_section(
        @section_picker_header,
        Encode.encode_gui_picker_header(to_wire_header(model))
      ),
      Wire.encode_section(
        @section_picker_query,
        Encode.encode_gui_picker_query(%{text: model.query})
      ),
      Wire.encode_section(
        @section_picker_items,
        Encode.encode_gui_picker_items(model.items)
      ),
      Wire.encode_section(
        @section_picker_action_menu,
        Encode.encode_gui_picker_action_menu(to_wire_action_menu(model.action_menu))
      ),
      Wire.encode_section(
        @section_picker_mode_prefix,
        Encode.encode_gui_picker_mode_prefix(%{text: model.mode_prefix})
      ),
      Wire.encode_section(
        @section_picker_load_status,
        Encode.encode_gui_picker_load_status(to_wire_load_status(model.load_status))
      )
    ]

    IO.iodata_to_binary([<<@op_gui_picker, length(sections)::8>> | sections])
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
