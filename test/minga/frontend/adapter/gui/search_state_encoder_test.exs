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

      assert <<@op_gui_search_state, 6::16, 0::8, 0::16, 0::16, 0::8>> = cmd
    end

    test "encodes active search state with matches" do
      model = %SearchState{
        active: true,
        match_count: 5,
        current_index: 2,
        case_sensitive: true,
        whole_word: false,
        regex: false,
        replace_mode: false
      }

      caches = Caches.new()
      {cmd, _caches} = SearchStateEncoder.encode(model, caches)

      assert <<@op_gui_search_state, 6::16, 1::8, 5::16, 2::16, 0x02::8>> = cmd
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
        case_sensitive: true,
        whole_word: true,
        regex: true,
        replace_mode: true
      }

      {cmd, _caches} = SearchStateEncoder.encode(model, Caches.new())

      assert <<@op_gui_search_state, 6::16, 1::8, 10::16, 3::16, 0x0F::8>> = cmd
    end

    test "rejects out-of-range match_count before narrowing it to u16" do
      model = %SearchState{
        active: true,
        match_count: 70_000,
        current_index: 1,
        case_sensitive: false,
        whole_word: false,
        regex: false,
        replace_mode: false
      }

      assert %{
               command: :gui_search_state,
               field: :match_count,
               actual: 70_000,
               min: 0,
               max: 65_535
             } =
               assert_raise(Minga.Frontend.Adapter.GUI.EncodingError, fn ->
                 SearchStateEncoder.encode(model, Caches.new())
               end)
    end

    test "rejects out-of-range current_index before narrowing it to u16" do
      model = %SearchState{
        active: true,
        match_count: 1,
        current_index: 70_000,
        case_sensitive: false,
        whole_word: false,
        regex: false,
        replace_mode: false
      }

      assert %{
               command: :gui_search_state,
               field: :current_index,
               actual: 70_000,
               min: 0,
               max: 65_535
             } =
               assert_raise(Minga.Frontend.Adapter.GUI.EncodingError, fn ->
                 SearchStateEncoder.encode(model, Caches.new())
               end)
    end
  end
end
