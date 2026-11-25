defmodule Minga.Frontend.Adapter.GUI.EmptyStateEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.EmptyState
  alias Minga.RenderModel.UI.EmptyState.Item
  alias Minga.RenderModel.UI.EmptyState.Section

  @op_gui_empty_state Opcodes.gui_empty_state()

  # Wire ids for the project home (payload version 2).
  # Ids 0, 2 and 3 belonged to the version 1 launchpad and stay retired.
  @section_ids %{recent: 1, projects: 4, tasks: 5, next: 6}
  @item_kinds %{recent_file: 1, action: 2, project: 4, task: 5}
  @payload_version 2

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
    writer =
      :gui_empty_state
      |> Writer.new()
      |> Writer.uint8(:payload_version, @payload_version)
      |> Writer.string16(:title, model.title)
      |> Writer.string16(:path, model.path)
      |> Writer.string16(:status, model.status)
      |> Writer.string16(:note, model.note)
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
      |> Writer.string16(:section_empty, section.empty)
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
    |> Writer.string16(:item_meta, item.meta)
    |> Writer.string8(:item_jump_key, item.jump_key || "")
    |> Writer.string8(:item_chord, item.chord)
    |> Writer.string8(:item_icon, item.icon)
    |> Writer.uint32(:item_icon_color, item.icon_color)
    |> Writer.string8(:item_state, state_name(item.state))
  end

  @spec state_name(atom() | nil) :: String.t()
  defp state_name(nil), do: ""
  defp state_name(state) when is_atom(state), do: Atom.to_string(state)
end
