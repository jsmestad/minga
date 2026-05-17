defmodule MingaEditor.Frontend.ProtocolDocumentSymbolsTest do
  @moduledoc """
  Tests for decoding the `DOCUMENT_SYMBOLS` (0x3E) parser opcode.
  """

  use ExUnit.Case, async: true

  alias Minga.Language.Symbol
  alias MingaEditor.Frontend.Protocol

  @op_document_symbols 0x3E
  @symbol_function 0
  @symbol_module 1
  @symbol_method 2
  @symbol_interface 3
  @symbol_test 4

  @spec encode_symbol(non_neg_integer(), String.t(), tuple()) :: binary()
  defp encode_symbol(kind, name, {start_row, start_col, end_row, end_col}) do
    <<kind::8, byte_size(name)::16, name::binary, start_row::32, start_col::32, end_row::32,
      end_col::32>>
  end

  describe "decode_event/1 — document_symbols (0x3E)" do
    test "decodes empty symbol list" do
      payload = <<@op_document_symbols, 7::32, 42::32, 0::32>>

      assert {:ok, {:document_symbols, 7, 42, []}} = Protocol.decode_event(payload)
    end

    test "decodes symbol entries with normalized kinds" do
      entries =
        encode_symbol(@symbol_function, "run", {1, 2, 4, 5}) <>
          encode_symbol(@symbol_module, "App", {0, 0, 10, 3}) <>
          encode_symbol(@symbol_method, "call", {6, 2, 8, 5}) <>
          encode_symbol(@symbol_interface, "Behaviour", {12, 0, 20, 3}) <>
          encode_symbol(@symbol_test, "renders", {22, 2, 24, 5})

      payload = <<@op_document_symbols, 3::32, 9::32, 5::32, entries::binary>>

      assert {:ok, {:document_symbols, 3, 9, symbols}} = Protocol.decode_event(payload)

      assert symbols == [
               %Symbol{kind: :function, name: "run", range: {1, 2, 4, 5}},
               %Symbol{kind: :module, name: "App", range: {0, 0, 10, 3}},
               %Symbol{kind: :method, name: "call", range: {6, 2, 8, 5}},
               %Symbol{kind: :interface, name: "Behaviour", range: {12, 0, 20, 3}},
               %Symbol{kind: :test, name: "renders", range: {22, 2, 24, 5}}
             ]
    end

    test "malformed entries fail explicitly" do
      payload = <<@op_document_symbols, 1::32, 1::32, 1::32, @symbol_function::8, 4::16, "abc">>

      assert {:error, :malformed} = Protocol.decode_event(payload)
    end
  end
end
