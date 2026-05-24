defmodule MingaEditor.Frontend.GUISearchTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.State.Search, as: SearchData
  alias Minga.Protocol.Opcodes

  @gui_action_search_query Opcodes.gui_action_search_query()
  @gui_action_search_next Opcodes.gui_action_search_next()
  @gui_action_search_prev Opcodes.gui_action_search_prev()
  @gui_action_search_replace Opcodes.gui_action_search_replace()
  @gui_action_search_replace_all Opcodes.gui_action_search_replace_all()
  @gui_action_search_dismiss Opcodes.gui_action_search_dismiss()

  # ── decode_gui_action ──

  describe "decode_gui_action for search_query" do
    test "decodes query with flags" do
      payload = <<5::16, "hello"::binary, 0x03::8>>

      assert {:ok, {:search_query, "hello", 3}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_query, payload)
    end

    test "decodes empty query" do
      payload = <<0::16, 0x00::8>>

      assert {:ok, {:search_query, "", 0}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_query, payload)
    end

    test "decodes query with all flags set" do
      payload = <<3::16, "foo"::binary, 0x0F::8>>

      assert {:ok, {:search_query, "foo", 0x0F}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_query, payload)
    end

    test "decodes non-ASCII query" do
      query = "café"
      len = byte_size(query)
      payload = <<len::16, query::binary, 0x00::8>>

      assert {:ok, {:search_query, ^query, 0}} =
               ProtocolGUI.decode_gui_action(@gui_action_search_query, payload)
    end

    test "returns error for truncated payload" do
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_search_query, <<0, 5, "hi">>)
    end

    test "returns error for empty payload" do
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_search_query, <<>>)
    end
  end

  describe "decode_gui_action for search_next/prev/dismiss" do
    test "decodes search_next" do
      assert {:ok, :search_next} == ProtocolGUI.decode_gui_action(@gui_action_search_next, <<>>)
    end

    test "decodes search_prev" do
      assert {:ok, :search_prev} == ProtocolGUI.decode_gui_action(@gui_action_search_prev, <<>>)
    end

    test "decodes search_dismiss" do
      assert {:ok, :search_dismiss} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_dismiss, <<>>)
    end

    test "search_next returns error with unexpected payload" do
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_search_next, <<0x01>>)
    end
  end

  describe "decode_gui_action for search_replace" do
    test "decodes replacement text" do
      payload = <<5::16, "earth"::binary>>

      assert {:ok, {:search_replace, "earth"}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_replace, payload)
    end

    test "decodes empty replacement" do
      assert {:ok, {:search_replace, ""}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_replace, <<0::16>>)
    end

    test "decodes non-ASCII replacement" do
      text = "été"
      len = byte_size(text)
      payload = <<len::16, text::binary>>

      assert {:ok, {:search_replace, ^text}} =
               ProtocolGUI.decode_gui_action(@gui_action_search_replace, payload)
    end
  end

  describe "decode_gui_action for search_replace_all" do
    test "decodes replacement text" do
      payload = <<3::16, "bar"::binary>>

      assert {:ok, {:search_replace_all, "bar"}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_replace_all, payload)
    end
  end

  # ── decode_search_flags ──

  describe "decode_search_flags/1" do
    test "decodes zero flags" do
      flags = ProtocolGUI.decode_search_flags(0)
      refute flags[:replace_mode]
      refute flags[:case_sensitive]
      refute flags[:whole_word]
      refute flags[:regex]
    end

    test "decodes replace_mode only" do
      flags = ProtocolGUI.decode_search_flags(0x01)
      assert flags[:replace_mode]
      refute flags[:case_sensitive]
    end

    test "decodes case_sensitive only" do
      flags = ProtocolGUI.decode_search_flags(0x02)
      refute flags[:replace_mode]
      assert flags[:case_sensitive]
    end

    test "decodes whole_word only" do
      flags = ProtocolGUI.decode_search_flags(0x04)
      assert flags[:whole_word]
      refute flags[:regex]
    end

    test "decodes regex only" do
      flags = ProtocolGUI.decode_search_flags(0x08)
      assert flags[:regex]
      refute flags[:whole_word]
    end

    test "decodes all flags set" do
      flags = ProtocolGUI.decode_search_flags(0x0F)
      assert flags[:replace_mode]
      assert flags[:case_sensitive]
      assert flags[:whole_word]
      assert flags[:regex]
    end
  end

  # ── encode_gui_search_state ──

  describe "encode_gui_search_state/4" do
    test "encodes active state with matches" do
      gs = %{replace_mode: true, case_sensitive: true, whole_word: false, regex: false}
      binary = ProtocolGUI.encode_gui_search_state(true, 5, 2, gs)

      <<0x9E, payload_len::16, active, count::16, idx::16, flags>> = binary
      assert payload_len == 6
      assert active == 1
      assert count == 5
      assert idx == 2
      assert flags == 0x03
    end

    test "encodes inactive state" do
      binary = ProtocolGUI.encode_gui_search_state(false, 0, 0, %{})

      <<0x9E, _len::16, active, count::16, idx::16, flags>> = binary
      assert active == 0
      assert count == 0
      assert idx == 0
      assert flags == 0
    end

    test "encodes all flags" do
      gs = %{replace_mode: true, case_sensitive: true, whole_word: true, regex: true}
      binary = ProtocolGUI.encode_gui_search_state(true, 0, 0, gs)

      <<0x9E, _len::16, _active, _count::16, _idx::16, flags>> = binary
      assert flags == 0x0F
    end

    test "clamps match_count to u16 max" do
      binary = ProtocolGUI.encode_gui_search_state(true, 70_000, 1, %{})

      <<0x9E, _len::16, _active, count::16, _idx::16, _flags>> = binary
      assert count == 65_535
    end

    test "clamps current_index to u16 max" do
      binary = ProtocolGUI.encode_gui_search_state(true, 1, 70_000, %{})

      <<0x9E, _len::16, _active, _count::16, idx::16, _flags>> = binary
      assert idx == 65_535
    end
  end

  # ── full event decode ──

  describe "full event decode for search actions" do
    @op_gui_action Opcodes.gui_action()

    test "decodes a complete search_query event" do
      binary = <<@op_gui_action, @gui_action_search_query, 3::16, "foo"::binary, 0x02>>

      assert {:ok, {:gui_action, {:search_query, "foo", 2}}} ==
               MingaEditor.Frontend.Protocol.decode_event(binary)
    end

    test "decodes a complete search_dismiss event" do
      binary = <<@op_gui_action, @gui_action_search_dismiss>>

      assert {:ok, {:gui_action, :search_dismiss}} ==
               MingaEditor.Frontend.Protocol.decode_event(binary)
    end
  end

  # ── Search state mutations ──

  describe "SearchData state mutations" do
    test "activate_gui_search sets all flags" do
      s = %SearchData{}
      result = SearchData.activate_gui_search(s, true, false, true)

      assert result.gui_search == %{
               replace_mode: false,
               case_sensitive: true,
               whole_word: false,
               regex: true
             }
    end

    test "gui_search_active? returns true when active" do
      s = SearchData.activate_gui_search(%SearchData{}, false, false, false)
      assert SearchData.gui_search_active?(s)
    end

    test "gui_search_active? returns false when nil" do
      refute SearchData.gui_search_active?(%SearchData{})
    end

    test "dismiss_gui_search sets gui_search to nil" do
      s = SearchData.activate_gui_search(%SearchData{}, false, false, false)
      result = SearchData.dismiss_gui_search(s)
      assert result.gui_search == nil
    end

    test "dismiss_gui_search preserves last_pattern" do
      s =
        %SearchData{}
        |> SearchData.record("hello", :forward)
        |> SearchData.activate_gui_search(false, false, false)
        |> SearchData.dismiss_gui_search()

      assert s.last_pattern == "hello"
    end

    test "update_gui_search_flags updates existing flags" do
      s = SearchData.activate_gui_search(%SearchData{}, false, false, false)
      result = SearchData.update_gui_search_flags(s, true, true, false)

      assert result.gui_search.case_sensitive == true
      assert result.gui_search.whole_word == true
      assert result.gui_search.replace_mode == false
    end

    test "update_gui_search_flags activates when nil" do
      result = SearchData.update_gui_search_flags(%SearchData{}, true, false, false)
      assert SearchData.gui_search_active?(result)
      assert result.gui_search.case_sensitive == true
      assert result.gui_search.replace_mode == false
    end

    test "set_gui_replace_mode updates when active" do
      s = SearchData.activate_gui_search(%SearchData{}, false, false, false)
      result = SearchData.set_gui_replace_mode(s, true)
      assert result.gui_search.replace_mode == true
    end

    test "set_gui_replace_mode is no-op when nil" do
      s = %SearchData{}
      result = SearchData.set_gui_replace_mode(s, true)
      assert result.gui_search == nil
    end
  end

  # ── Search engine flag support ──

  describe "Search.find_next with opts" do
    alias Minga.Editing.Search

    test "case-insensitive search finds uppercase match" do
      assert {0, 0} ==
               Search.find_next("Hello world", "hello", {0, 0}, :forward, case_sensitive: false)
    end

    test "case-sensitive search does not find mismatched case" do
      assert nil ==
               Search.find_next("Hello world", "hello", {0, 0}, :forward, case_sensitive: true)
    end

    test "whole-word search skips partial matches" do
      assert {0, 7} == Search.find_next("foobar foo", "foo", {0, 0}, :forward, whole_word: true)
    end

    test "whole-word search finds standalone word" do
      assert {0, 0} == Search.find_next("foo bar", "foo", {0, 0}, :forward, whole_word: true)
    end

    test "regex search finds pattern" do
      assert {0, 3} == Search.find_next("abc123 def", "\\d+", {0, 0}, :forward, regex: true)
    end

    test "regex search wraps regex metacharacters when not in regex mode" do
      assert {0, 0} == Search.find_next("a.b other", "a.b", {0, 0}, :forward, regex: false)
    end

    test "regex mode treats dot as wildcard" do
      assert {0, 0} == Search.find_next("axb other", "a.b", {0, 0}, :forward, regex: true)
    end
  end

  describe "Search.find_all_in_range with opts" do
    alias Minga.Editing.Search

    test "case-insensitive finds all case variants" do
      lines = ["Hello hello HELLO"]
      matches = Search.find_all_in_range(lines, "hello", 0, case_sensitive: false)
      assert length(matches) == 3
    end

    test "whole-word skips partial matches" do
      lines = ["foobar foo barfoo"]
      matches = Search.find_all_in_range(lines, "foo", 0, whole_word: true)
      assert [%{col: 7}] = matches
    end

    test "regex finds pattern matches" do
      lines = ["abc 1 def 2"]
      matches = Search.find_all_in_range(lines, "\\d+", 0, regex: true)
      assert length(matches) == 2
    end
  end

  describe "Search.substitute with opts" do
    alias Minga.Editing.Search

    test "case-insensitive substitute replaces all case variants" do
      {result, count} =
        Search.substitute("Hello hello HELLO", "hello", "world", true, case_sensitive: false)

      assert result == "world world world"
      assert count == 3
    end

    test "whole-word substitute skips partial matches" do
      {result, count} =
        Search.substitute("foobar foo barfoo", "foo", "baz", true, whole_word: true)

      assert result == "foobar baz barfoo"
      assert count == 1
    end
  end
end
