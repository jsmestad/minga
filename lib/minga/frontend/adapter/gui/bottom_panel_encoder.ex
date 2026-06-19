defmodule Minga.Frontend.Adapter.GUI.BottomPanelEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.BottomPanel

  @op_gui_bottom_panel Opcodes.gui_bottom_panel()

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
    <<@op_gui_bottom_panel, 0>>
  end

  defp encode_binary(%BottomPanel{} = model) do
    tab_defs =
      for {type_byte, name} <- model.tabs, into: <<>> do
        <<type_byte::8, byte_size(name)::8, name::binary>>
      end

    header =
      <<@op_gui_bottom_panel, 1, model.active_tab_index::8, model.height_percent::8,
        model.filter_byte::8, length(model.tabs)::8, tab_defs::binary>>

    header <> encode_messages(model.stream_instance, model.messages)
  end

  @spec encode_messages(non_neg_integer(), [BottomPanel.MessageEntry.t()]) :: binary()
  defp encode_messages(stream_instance, entries) do
    entry_data =
      for entry <- entries, into: <<>> do
        path_bytes = entry.file_path || ""

        <<entry.id::32, entry.level_byte::8, entry.subsystem_byte::8, entry.ts_secs::32,
          byte_size(path_bytes)::16, path_bytes::binary, byte_size(entry.text)::16,
          entry.text::binary>>
      end

    <<stream_instance::32, length(entries)::16, entry_data::binary>>
  end
end
