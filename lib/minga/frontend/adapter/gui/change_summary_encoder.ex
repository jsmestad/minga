defmodule Minga.Frontend.Adapter.GUI.ChangeSummaryEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
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

    writer =
      :gui_change_summary
      |> Writer.new()
      |> Writer.append(<<@op_gui_change_summary>>)
      |> Writer.uint8(:visible, visible)
      |> Writer.uint16(:selected_index, selected_index)
      |> Writer.uint16(:entry_count, Enum.count(entries))

    entries
    |> Enum.reduce(writer, fn entry, acc ->
      acc
      |> Writer.string16(:entry_path, entry.path)
      |> Writer.uint8(:entry_action, action_byte(entry.action))
      |> Writer.uint32(:lines_added, entry.lines_added)
      |> Writer.uint32(:lines_removed, entry.lines_removed)
    end)
    |> Writer.finish()
  end

  @spec action_byte(ChangeSummary.Entry.action()) :: non_neg_integer()
  defp action_byte(:modified), do: 0
  defp action_byte(:added), do: 1
  defp action_byte(:deleted), do: 2
  defp action_byte(:renamed), do: 3
  defp action_byte(_), do: 0
end
