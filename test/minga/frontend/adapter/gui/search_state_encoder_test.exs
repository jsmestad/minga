defmodule Minga.Frontend.Adapter.GUI.SearchStateEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.SearchStateEncoder
  alias Minga.RenderModel.UI.SearchState
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_search_state Minga.Protocol.Opcodes.gui_search_state()

  describe "encode/2" do
    test "encodes inactive search state" do
      model = %SearchState{active: false}
      caches = Caches.new()

      {cmd, _caches} = SearchStateEncoder.encode(model, caches)

      assert <<@op_gui_search_state, _len::16, 0::8, 0::16, 0::16, _flags::8>> = cmd
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

      assert <<@op_gui_search_state, _len::16, 1::8, 5::16, 2::16, _flags::8>> = cmd
    end

    test "returns nil on second call with same model (fingerprint skip)" do
      model = %SearchState{active: false}
      caches = Caches.new()

      {cmd1, caches} = SearchStateEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = SearchStateEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "produces byte-identical output to legacy ProtocolGUI for inactive state" do
      legacy_binary = ProtocolGUI.encode_gui_search_state(false, 0, 0, %{})

      # When inactive, the builder sets all flags to false (matching legacy %{} behavior)
      model = %SearchState{
        active: false,
        case_sensitive: false,
        whole_word: false,
        regex: false,
        replace_mode: false
      }

      caches = Caches.new()
      {new_binary, _caches} = SearchStateEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "Inactive search state: new encoder output does not match legacy output"
    end

    test "produces byte-identical output to legacy ProtocolGUI for active state with flags" do
      gs = %{case_sensitive: true, whole_word: false, regex: false, replace_mode: false}
      legacy_binary = ProtocolGUI.encode_gui_search_state(true, 5, 2, gs)

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
      {new_binary, _caches} = SearchStateEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "Active search state: new encoder output does not match legacy output"
    end

    test "produces byte-identical output to legacy ProtocolGUI for all flag combinations" do
      flag_combos = [
        %{case_sensitive: true, whole_word: true, regex: true, replace_mode: true},
        %{case_sensitive: false, whole_word: false, regex: false, replace_mode: false},
        %{case_sensitive: true, whole_word: false, regex: true, replace_mode: false},
        %{case_sensitive: false, whole_word: true, regex: false, replace_mode: true}
      ]

      for gs <- flag_combos do
        legacy_binary = ProtocolGUI.encode_gui_search_state(true, 10, 3, gs)

        model = %SearchState{
          active: true,
          match_count: 10,
          current_index: 3,
          case_sensitive: gs.case_sensitive,
          whole_word: gs.whole_word,
          regex: gs.regex,
          replace_mode: gs.replace_mode
        }

        caches = Caches.new()
        {new_binary, _caches} = SearchStateEncoder.encode(model, caches)

        assert new_binary == legacy_binary,
               "Search state flags #{inspect(gs)}: new encoder output does not match legacy output"
      end
    end

    test "clamps match_count and current_index to u16 max" do
      legacy_binary = ProtocolGUI.encode_gui_search_state(true, 70_000, 70_000, %{})

      model = %SearchState{
        active: true,
        match_count: 70_000,
        current_index: 70_000,
        case_sensitive: false,
        whole_word: false,
        regex: false,
        replace_mode: false
      }

      caches = Caches.new()
      {new_binary, _caches} = SearchStateEncoder.encode(model, caches)

      assert new_binary == legacy_binary
    end
  end
end
