defmodule Minga.Frontend.Adapter.GUI.SearchStateEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.SearchStateEncoder
  alias Minga.RenderModel.UI.SearchState

  @op_gui_search_state Minga.Protocol.Opcodes.gui_search_state()

  describe "encode/2" do
    test "encodes inactive search state" do
      model = %SearchState{
        active: false,
        case_sensitive: false,
        whole_word: false,
        regex: false,
        replace_mode: false
      }

      caches = Caches.new()

      {cmd, _caches} = SearchStateEncoder.encode(model, caches)

      assert <<@op_gui_search_state, 21::16, 0::8, 0::32, 0::32, 0::8, 0::16, 0::32, 0::32, 0::8>> =
               cmd
    end

    test "encodes active search state with matches" do
      model = %SearchState{
        active: true,
        match_count: 5,
        current_index: 2,
        query: "café",
        session_id: 3,
        acknowledged_edit_seq: 2,
        case_sensitive: true,
        whole_word: false,
        regex: false,
        replace_mode: false
      }

      caches = Caches.new()
      {cmd, _caches} = SearchStateEncoder.encode(model, caches)

      assert <<@op_gui_search_state, 26::16, 1::8, 5::32, 2::32, 0x02::8, 5::16, "café"::binary,
               3::32, 2::32, 0::8>> = cmd
    end

    test "returns nil on second call with same model (fingerprint skip)" do
      model = %SearchState{active: false}
      caches = Caches.new()

      {cmd1, caches} = SearchStateEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = SearchStateEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "encodes all four search option flags" do
      model = %SearchState{
        active: true,
        match_count: 10,
        current_index: 3,
        query: "foo",
        session_id: 10,
        acknowledged_edit_seq: 8,
        case_sensitive: true,
        whole_word: true,
        regex: true,
        replace_mode: true
      }

      {cmd, _caches} = SearchStateEncoder.encode(model, Caches.new())

      assert <<@op_gui_search_state, 24::16, 1::8, 10::32, 3::32, 0x0F::8, 3::16, "foo"::binary,
               10::32, 8::32, 0::8>> = cmd
    end

    test "encodes counts at and beyond the former u16 limit" do
      for count <- [65_535, 65_536, 70_000] do
        model = %SearchState{
          active: true,
          match_count: count,
          current_index: count,
          case_sensitive: false,
          whole_word: false,
          regex: false,
          replace_mode: false
        }

        {cmd, _caches} = SearchStateEncoder.encode(model, Caches.new())

        assert <<@op_gui_search_state, _len::16, 1::8, ^count::32, ^count::32, _rest::binary>> =
                 cmd
      end
    end

    test "encodes a current ordinal beyond the former u16 limit" do
      model = %SearchState{
        active: true,
        match_count: 1,
        current_index: 70_000,
        case_sensitive: false,
        whole_word: false,
        regex: false,
        replace_mode: false
      }

      {cmd, _caches} = SearchStateEncoder.encode(model, Caches.new())
      assert <<@op_gui_search_state, _len::16, 1::8, 1::32, 70_000::32, _rest::binary>> = cmd
    end

    test "encodes every typed pending and failure status" do
      for {status, wire} <- [ready: 0, loading: 1, rebuilding: 2, failed: 3] do
        model = %SearchState{active: true, status: status}
        {cmd, _caches} = SearchStateEncoder.encode(model, Caches.new())
        assert <<@op_gui_search_state, 21::16, _prefix::binary-size(20), ^wire::8>> = cmd
      end
    end
  end
end
