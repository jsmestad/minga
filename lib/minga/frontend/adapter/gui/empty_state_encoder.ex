defmodule Minga.Frontend.Adapter.GUI.EmptyStateEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
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
    :gui_empty_state
    |> Writer.new()
    |> Writer.append(<<@op_gui_empty_state>>)
    |> Writer.payload16(:payload, encode_payload(model))
    |> Writer.finish()
  end

  @spec encode_payload(EmptyState.t()) :: binary()
  defp encode_payload(%EmptyState{} = model) do
    flags = if model.crashed?, do: 0x01, else: 0x00

    writer =
      :gui_empty_state
      |> Writer.new()
      |> Writer.append(<<1::8>>)
      |> Writer.uint8(:flags, flags)
      |> Writer.string8(:version, model.version)
      |> Writer.string8(:focused_id, model.focused_id || "")
      |> Writer.uint8(:section_count, Enum.count(model.sections))

    model.sections
    |> Enum.reduce(writer, &encode_section/2)
    |> Writer.finish()
  end

  @spec encode_section(Section.t(), Writer.t()) :: Writer.t()
  defp encode_section(%Section{} = section, %Writer{} = writer) do
    writer =
      writer
      |> Writer.uint8(:section_id, Map.fetch!(@section_ids, section.id))
      |> Writer.string8(:section_title, section.title)
      |> Writer.uint8(:section_item_count, Enum.count(section.items))

    Enum.reduce(section.items, writer, &encode_item/2)
  end

  @spec encode_item(Item.t(), Writer.t()) :: Writer.t()
  defp encode_item(%Item{} = item, %Writer{} = writer) do
    writer
    |> Writer.uint8(:item_kind, Map.fetch!(@item_kinds, item.kind))
    |> Writer.string8(:item_id, item.id)
    |> Writer.string16(:item_label, item.label)
    |> Writer.string16(:item_detail, item.detail)
    |> Writer.string8(:item_jump_key, item.jump_key || "")
    |> Writer.string8(:item_chord, item.chord)
    |> Writer.string8(:item_icon, item.icon)
    |> Writer.uint32(:item_icon_color, item.icon_color)
  end
end
