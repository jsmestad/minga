defmodule Minga.Frontend.Adapter.GUI.ChangeSummaryEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.ChangeSummary

  @op_gui_change_summary Opcodes.gui_change_summary()

  @spec encode(ChangeSummary.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%ChangeSummary{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_change_summary_fp do
      {encode_binary(model), %{caches | last_change_summary_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_binary(ChangeSummary.t()) :: binary()
  defp encode_binary(%ChangeSummary{entries: entries, selected_index: selected_index}) do
    visible = if entries == [], do: 0, else: 1

    entry_binaries =
      Enum.map(entries, fn entry ->
        path_bytes = :erlang.iolist_to_binary([entry.path])
        action_byte = action_byte(entry.action)

        <<byte_size(path_bytes)::16, path_bytes::binary, action_byte::8, entry.lines_added::32,
          entry.lines_removed::32>>
      end)

    IO.iodata_to_binary([
      <<@op_gui_change_summary, visible::8, selected_index::16, length(entries)::16>>
      | entry_binaries
    ])
  end

  @spec action_byte(ChangeSummary.Entry.action()) :: non_neg_integer()
  defp action_byte(:modified), do: 0
  defp action_byte(:added), do: 1
  defp action_byte(:deleted), do: 2
  defp action_byte(:renamed), do: 3
  defp action_byte(_), do: 0
end
