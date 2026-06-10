defmodule Minga.Frontend.Adapter.GUI.CompletionEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.Completion.Item

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

    # Byte-exactness against the schema-generated codec is now proven by the
    # cross-language golden tests (test/support/protocol_golden.ex +
    # go/tui/internal/protocol/golden_cross_lang_test.go), which replaced the
    # former hand-written ProtocolGUI parity oracle for this family.
    test "encodes the visible window header and items" do
      model = %Completion{
        visible?: true,
        cursor_row: 5,
        cursor_col: 2,
        selected_offset: 1,
        items: [
          %Item{kind: :function, label: "map", detail: "Enum.map/2"},
          %Item{kind: :variable, label: "value", detail: ""}
        ]
      }

      <<@op_gui_completion, 1::8, 5::16, 2::16, 1::16, count::16, rest::binary>> =
        CompletionEncoder.encode_command(model)

      assert count == 2

      <<1::8, label_len::16, label::binary-size(label_len), detail_len::16,
        detail::binary-size(detail_len), _next::binary>> = rest

      assert label == "map"
      assert detail == "Enum.map/2"
    end
  end
end
