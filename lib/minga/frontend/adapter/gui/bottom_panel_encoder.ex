defmodule Minga.Frontend.Adapter.GUI.BottomPanelEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.BottomPanel
  alias Minga.RenderModel.UI.BottomPanel.MessageEntry

  @op_gui_bottom_panel Opcodes.gui_bottom_panel()
  @command :gui_bottom_panel

  @spec encode(BottomPanel.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%BottomPanel{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_bottom_panel_fp do
      {encode_binary(model), %{caches | last_bottom_panel_fp: fp}}
    else
      {nil, caches}
    end
  end

  # Wire format:
  #   visible: opcode + visible=1(1) + active_tab_index(1) + height_percent(1)
  #            + filter(1) + tab_count(1) + tab_defs... + content
  #   tab_def: tab_type(1) + name_len(1) + name
  #   content: stream_instance(4) + entry_count(2) + entries...
  #   entry: id(4) + level(1) + subsystem(1) + ts_secs(4)
  #          + path_len(2) + path + text_len(2) + text
  #   hidden: opcode + visible=0(1)
  @spec encode_binary(BottomPanel.t()) :: binary()
  defp encode_binary(%BottomPanel{visible?: false}) do
    Writer.new(@command)
    |> Writer.uint8(:opcode, @op_gui_bottom_panel)
    |> Writer.uint8(:visible, 0)
    |> Writer.finish()
  end

  defp encode_binary(%BottomPanel{} = model) do
    Writer.new(@command)
    |> Writer.uint8(:opcode, @op_gui_bottom_panel)
    |> Writer.uint8(:visible, 1)
    |> Writer.uint8(:active_tab_index, model.active_tab_index)
    |> Writer.uint8(:height_percent, model.height_percent)
    |> Writer.uint8(:filter, model.filter_byte)
    |> Writer.uint8(:tab_count, Enum.count(model.tabs))
    |> Writer.append(Enum.map(model.tabs, &encode_tab/1))
    |> Writer.append(encode_messages(model.stream_instance, model.messages))
    |> Writer.finish()
  end

  @spec encode_tab(BottomPanel.tab()) :: binary()
  defp encode_tab({type_byte, name}) do
    Writer.new(@command)
    |> Writer.uint8(:tab_type, type_byte)
    |> Writer.string8(:tab_name, name)
    |> Writer.finish()
  end

  @spec encode_messages(BottomPanel.stream_instance(), [MessageEntry.t()]) :: binary()
  defp encode_messages(stream_instance, entries) do
    Writer.new(@command)
    |> Writer.uint32(:stream_instance, stream_instance)
    |> Writer.uint16(:entry_count, Enum.count(entries))
    |> Writer.append(Enum.map(entries, &encode_message/1))
    |> Writer.finish()
  end

  @spec encode_message(MessageEntry.t()) :: binary()
  defp encode_message(%MessageEntry{} = entry) do
    Writer.new(@command)
    |> Writer.uint32(:message_id, entry.id)
    |> Writer.uint8(:message_level, entry.level_byte)
    |> Writer.uint8(:message_subsystem, entry.subsystem_byte)
    |> Writer.uint32(:message_timestamp, entry.ts_secs)
    |> Writer.string16(:message_path, entry.file_path || "")
    |> Writer.string16(:message_text, entry.text)
    |> Writer.finish()
  end
end
