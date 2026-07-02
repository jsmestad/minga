defmodule Minga.Frontend.Adapter.GUI.EmptyStateEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.EmptyState
  alias Minga.RenderModel.UI.EmptyState.Item
  alias Minga.RenderModel.UI.EmptyState.Section

  @op_gui_empty_state Opcodes.gui_empty_state()

  @section_ids %{session: 0, recent: 1, start: 2, footer: 3}
  @item_kinds %{resume: 0, recent_file: 1, action: 2, hint: 3}

  @spec encode(EmptyState.t() | nil, Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(nil, %Caches{} = caches), do: encode(%EmptyState{}, caches)

  def encode(%EmptyState{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_empty_state_fp do
      {encode_command(model), %{caches | last_empty_state_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(EmptyState.t()) :: binary()
  def encode_command(%EmptyState{visible?: false}) do
    <<@op_gui_empty_state, 1::16, 0::8>>
  end

  def encode_command(%EmptyState{} = model) do
    payload = encode_payload(model)
    <<@op_gui_empty_state, byte_size(payload)::16, payload::binary>>
  end

  @spec encode_payload(EmptyState.t()) :: binary()
  defp encode_payload(%EmptyState{} = model) do
    flags = if model.crashed?, do: 0x01, else: 0x00

    IO.iodata_to_binary([
      <<1::8, flags::8>>,
      string8(model.version),
      string8(model.focused_id || ""),
      <<Enum.count(model.sections)::8>>,
      Enum.map(model.sections, &encode_section/1)
    ])
  end

  @spec encode_section(Section.t()) :: iodata()
  defp encode_section(%Section{} = section) do
    [
      <<Map.fetch!(@section_ids, section.id)::8>>,
      string8(section.title),
      <<Enum.count(section.items)::8>>,
      Enum.map(section.items, &encode_item/1)
    ]
  end

  @spec encode_item(Item.t()) :: iodata()
  defp encode_item(%Item{} = item) do
    [
      <<Map.fetch!(@item_kinds, item.kind)::8>>,
      string8(item.id),
      string16(item.label),
      string16(item.detail),
      string8(item.jump_key || ""),
      string8(item.chord),
      string8(item.icon),
      <<item.icon_color::32>>
    ]
  end

  @spec string8(String.t()) :: binary()
  defp string8(value), do: value |> Wire.utf8_prefix_bytes(255) |> Wire.encode_string8()

  @spec string16(String.t()) :: binary()
  defp string16(value),
    do: value |> Wire.utf8_prefix_bytes(Wire.max_u16()) |> Wire.encode_string16()
end
