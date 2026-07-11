defmodule Minga.Frontend.Adapter.GUI.CompletionEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.Frontend.Adapter.GUI.EncodingError
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

    test "re-encodes when only the documentation changes" do
      base = %Completion{
        visible?: true,
        cursor_row: 5,
        cursor_col: 0,
        items: [%Item{kind: :function, label: "map", detail: "Enum.map/2"}],
        documentation: "First doc"
      }

      moved = %{base | documentation: "Second doc"}

      caches = Caches.new()
      {cmd1, caches} = CompletionEncoder.encode(base, caches)
      assert cmd1 != nil

      # A selection move re-emits completion with the newly-selected item's docs;
      # the fingerprint includes documentation, so the encoder must re-fire.
      {cmd2, _caches} = CompletionEncoder.encode(moved, caches)
      assert cmd2 != nil
      assert cmd2 == CompletionEncoder.encode_command(moved)
    end

    test "encodes the documentation tail after the items" do
      model = %Completion{
        visible?: true,
        cursor_row: 5,
        cursor_col: 2,
        selected_offset: 0,
        items: [%Item{kind: :function, label: "map", detail: "Enum.map/2"}],
        documentation: "Applies fun."
      }

      <<@op_gui_completion, 1::8, _row::16, _col::16, _sel::16, 1::16, _kind::8, label_len::16,
        _label::binary-size(label_len), detail_len::16, _detail::binary-size(detail_len),
        doc_len::16, doc::binary-size(doc_len)>> =
        CompletionEncoder.encode_command(model)

      assert doc == "Applies fun."
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

    test "rejects every oversized completion coordinate with command-scoped metadata" do
      base = %Completion{visible?: true}

      for field <- [:cursor_row, :cursor_col, :selected_offset] do
        model = Map.put(base, field, 65_536)
        assert_encoding_error(model, field, 65_536)
      end
    end

    test "rejects oversized completion item counts and strings without truncation" do
      item = %Item{kind: :function, label: "map", detail: "Enum.map/2"}

      assert_encoding_error(
        %Completion{visible?: true, items: List.duplicate(item, 65_536)},
        :item_count,
        65_536
      )

      oversized = String.duplicate("x", 65_536)

      for {field, item} <- [
            item_label: %{item | label: oversized},
            item_detail: %{item | detail: oversized}
          ] do
        assert_encoding_error(%Completion{visible?: true, items: [item]}, field, 65_536)
      end

      assert_encoding_error(
        %Completion{visible?: true, documentation: oversized},
        :documentation,
        65_536
      )
    end
  end

  defp assert_encoding_error(model, field, actual) do
    error = assert_raise EncodingError, fn -> CompletionEncoder.encode_command(model) end

    assert %EncodingError{
             command: :gui_completion,
             field: ^field,
             actual: ^actual,
             min: 0,
             max: 65_535
           } = error
  end
end
