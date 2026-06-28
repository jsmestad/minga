defmodule MingaEditor.Frontend.GUICompletionProtocolTest do
  @moduledoc "Tests for GUI completion protocol encoding."
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion, as: EditingCompletion
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.Completion.Item

  @op_gui_completion Minga.Protocol.Opcodes.gui_completion()

  test "encode_command sends the visible completion window and selected offset" do
    comp = many_items_completion(15)
    comp = %{comp | selected: 7}

    <<@op_gui_completion, 1, 4::16, 12::16, selected_offset::16, count::16, entries::binary>> =
      comp |> completion_model(4, 12) |> CompletionEncoder.encode_command()

    assert selected_offset == 5
    assert count == 10
    assert decode_labels(entries, count) == Enum.map(2..11, &label/1)
  end

  test "selection move does not re-encode the popup (fingerprint excludes selected_offset)" do
    comp = many_items_completion(5)
    model = completion_model(comp, 4, 12)

    alias Minga.Frontend.Adapter.GUI.Caches
    {first_encode, caches} = CompletionEncoder.encode(model, %Caches{})
    assert first_encode != nil

    moved_model = %{model | selected_offset: model.selected_offset + 1}
    {second_encode, _caches} = CompletionEncoder.encode(moved_model, caches)
    assert second_encode == nil
  end

  # Mirror the production CompletionBuilder transformation: window the legacy
  # completion via visible_items, then map to the semantic Completion model the
  # generated encoder consumes.
  defp completion_model(comp, cursor_row, cursor_col) do
    {visible_items, selected_offset} = EditingCompletion.visible_items(comp)

    %Completion{
      visible?: true,
      cursor_row: cursor_row,
      cursor_col: cursor_col,
      selected_offset: selected_offset,
      items:
        Enum.map(visible_items, fn item ->
          %Item{kind: item.kind, label: item.label, detail: item.detail || ""}
        end)
    }
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
    |> EditingCompletion.new({0, 0})
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
