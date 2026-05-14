defmodule MingaEditor.Frontend.GUICompletionProtocolTest do
  @moduledoc "Tests for GUI completion protocol encoding."
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion
  alias MingaEditor.Frontend.Protocol.GUI

  test "encode_gui_completion sends the visible completion window and selected offset" do
    comp = many_items_completion(15)
    comp = %{comp | selected: 7}

    <<0x73, 1, 4::16, 12::16, selected_offset::16, count::16, entries::binary>> =
      GUI.encode_gui_completion(comp, 4, 12)

    assert selected_offset == 5
    assert count == 10
    assert decode_labels(entries, count) == Enum.map(2..11, &label/1)
  end

  defp many_items_completion(count) do
    0..(count - 1)
    |> Enum.map(fn index ->
      label = label(index)

      %{
        label: label,
        kind: :function,
        insert_text: label,
        filter_text: label,
        detail: "",
        documentation: "",
        sort_text: label,
        text_edit: nil,
        raw: nil
      }
    end)
    |> Completion.new({0, 0})
  end

  defp label(index), do: "item_" <> String.pad_leading(Integer.to_string(index), 2, "0")

  defp decode_labels(entries, count), do: decode_labels(entries, count, [])
  defp decode_labels(_entries, 0, acc), do: Enum.reverse(acc)

  defp decode_labels(
         <<_kind, label_len::16, label::binary-size(label_len), detail_len::16,
           _detail::binary-size(detail_len), rest::binary>>,
         count,
         acc
       ) do
    decode_labels(rest, count - 1, [label | acc])
  end
end
