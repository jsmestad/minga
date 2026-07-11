defmodule Minga.Frontend.Adapter.GUI.EditTimelineEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.EditTimeline
  alias Minga.RenderModel.UI.EditTimeline.Entry
  alias Minga.RenderModel.UI.EditTimeline.FileEntry

  @op_gui_edit_timeline Opcodes.gui_edit_timeline()
  @command :gui_edit_timeline

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
    payload =
      Writer.new(@command)
      |> Writer.uint8(:visible, if(model.visible?, do: 1, else: 0))
      |> encode_viewing_index(model.viewing_index)
      |> Writer.uint8(:entry_count, Enum.count(model.entries))
      |> Writer.append(Enum.map(model.entries, &encode_entry/1))
      |> Writer.append(encode_files(model.files))
      |> Writer.finish()

    Writer.new(@command)
    |> Writer.uint8(:opcode, @op_gui_edit_timeline)
    |> Writer.payload16(:payload, payload)
    |> Writer.finish()
  end

  @spec encode_viewing_index(Writer.t(), non_neg_integer() | nil) :: Writer.t()
  defp encode_viewing_index(writer, nil), do: Writer.uint16(writer, :viewing_index, 0xFFFF)

  defp encode_viewing_index(writer, index),
    do: Writer.uint16(writer, :viewing_index, index, 0xFFFE)

  @spec encode_entry(Entry.t()) :: binary()
  defp encode_entry(%Entry{} = entry) do
    Writer.new(@command)
    |> Writer.uint8(:entry_index, entry.index)
    |> Writer.string8(:tool_name, entry.tool_name)
    |> Writer.uint32(:timestamp_delta, entry.timestamp_delta)
    |> Writer.finish()
  end

  @spec encode_files([FileEntry.t()]) :: binary()
  defp encode_files(files) do
    Writer.new(@command)
    |> Writer.uint8(:file_count, Enum.count(files))
    |> Writer.append(Enum.map(files, &encode_file/1))
    |> Writer.finish()
  end

  @spec encode_file(FileEntry.t()) :: binary()
  defp encode_file(%FileEntry{} = file) do
    Writer.new(@command)
    |> Writer.string16(:path, file.path)
    |> Writer.uint8(:file_entry_count, file.entry_count)
    |> Writer.uint32(:lines_added, file.lines_added)
    |> Writer.uint32(:lines_removed, file.lines_removed)
    |> Writer.uint8(:review_status, review_status_to_byte(file.review_status))
    |> Writer.finish()
  end

  @spec review_status_to_byte(FileEntry.review_status()) :: non_neg_integer()
  defp review_status_to_byte(:pending), do: 0
  defp review_status_to_byte(:reviewing), do: 1
end
