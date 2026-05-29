defmodule Minga.Frontend.Adapter.GUI.CompletionEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion, as: EditingCompletion
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.Completion.Item
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_completion Minga.Protocol.Opcodes.gui_completion()

  describe "encode/2" do
    test "encodes hidden completion" do
      model = %Completion{}
      caches = Caches.new()

      {cmd, _caches} = CompletionEncoder.encode(model, caches)

      assert cmd == <<@op_gui_completion, 0::8>>
    end

    test "returns nil on second call with same fingerprint" do
      model = %Completion{}
      caches = Caches.new()

      {cmd1, caches} = CompletionEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = CompletionEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when semantic fields change" do
      model1 = %Completion{}

      model2 = %Completion{
        visible?: true,
        cursor_row: 5,
        cursor_col: 0,
        items: [%Item{kind: :function, label: "map", detail: "Enum.map/2"}]
      }

      caches = Caches.new()
      {_, caches} = CompletionEncoder.encode(model1, caches)
      {cmd2, _caches} = CompletionEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == CompletionEncoder.encode_command(model2)
    end

    test "produces byte-identical output to legacy ProtocolGUI for hidden state" do
      model = %Completion{}

      assert CompletionEncoder.encode_command(model) ==
               ProtocolGUI.encode_gui_completion(nil, 0, 0)
    end

    test "produces byte-identical output to legacy ProtocolGUI for visible items" do
      legacy_completion =
        EditingCompletion.new(
          [
            item("map", :function, "Enum.map/2"),
            item("value", :variable, nil)
          ],
          {0, 0}
        )

      {visible_items, selected_offset} = EditingCompletion.visible_items(legacy_completion)

      model = %Completion{
        visible?: true,
        cursor_row: 5,
        cursor_col: 2,
        selected_offset: selected_offset,
        items:
          Enum.map(visible_items, fn item ->
            %Item{kind: item.kind, label: item.label, detail: item.detail || ""}
          end)
      }

      assert CompletionEncoder.encode_command(model) ==
               ProtocolGUI.encode_gui_completion(legacy_completion, 5, 2)
    end
  end

  defp item(label, kind, detail) do
    %{
      label: label,
      kind: kind,
      insert_text: label,
      filter_text: label,
      detail: detail,
      documentation: "",
      sort_text: label,
      text_edit: nil,
      raw: nil
    }
  end
end
