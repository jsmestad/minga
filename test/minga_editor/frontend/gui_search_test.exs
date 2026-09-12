defmodule MingaEditor.Frontend.GUISearchTest do
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.RenderModel.UI.SearchStateBuilder
  alias MingaEditor.Session.State
  alias MingaEditor.State.Buffers
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

    test "invalid regex falls back to literal match" do
      assert {0, 4} == Search.find_next("foo [bar baz", "[bar", {0, 0}, :forward, regex: true)
    end

    test "invalid regex returns nil when literal not found" do
      assert nil == Search.find_next("foo bar", "[missing", {0, 0}, :forward, regex: true)
    end
  end

  describe "Search.find_all_in_range with opts" do
    alias Minga.Editing.Search

    test "case-insensitive finds all case variants" do
      lines = ["Hello hello HELLO"]
      matches = Search.find_all_in_range(lines, "hello", 0, case_sensitive: false)
      assert Enum.count(matches) == 3
    end

    test "whole-word skips partial matches" do
      lines = ["foobar foo barfoo"]
      matches = Search.find_all_in_range(lines, "foo", 0, whole_word: true)
      assert [%{col: 7}] = matches
    end

    test "regex finds pattern matches" do
      lines = ["abc 1 def 2"]
      matches = Search.find_all_in_range(lines, "\\d+", 0, regex: true)
      assert Enum.count(matches) == 2
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

  describe "production toolbar Replace route" do
    test "replaces the highlighted middle match before advancing" do
      ctx = start_editor("foo foo foo")
      select_first_match(ctx, "foo")
      send_search_action(ctx, :next)

      assert Buffer.cursor(ctx.buffer) == {0, 4}

      send_search_action(ctx, {:replace, "bar"})

      assert Buffer.content(ctx.buffer) == "foo bar foo"
      assert Buffer.cursor(ctx.buffer) == {0, 8}
      assert_search_stats(ctx, 2, 2)
    end

    test "advances to an adjacent match at the replacement cursor" do
      ctx = start_editor("foofoo foo")
      select_first_match(ctx, "foo")

      send_search_action(ctx, {:replace, "bar"})

      assert Buffer.content(ctx.buffer) == "barfoo foo"
      assert Buffer.cursor(ctx.buffer) == {0, 3}
      assert_search_stats(ctx, 2, 1)
    end

    test "replaces an overlapping selected match and advances to the next remaining match" do
      ctx = start_editor("aaa aa")
      select_first_match(ctx, "aa")
      send_search_action(ctx, :next)
      assert Buffer.cursor(ctx.buffer) == {0, 1}

      send_search_action(ctx, {:replace, "X"})

      assert Buffer.content(ctx.buffer) == "aX aa"
      assert Buffer.cursor(ctx.buffer) == {0, 3}
      assert_search_stats(ctx, 1, 1)
    end

    test "replaces first, last with wraparound, and a single remaining match in order" do
      first = start_editor("foo foo foo")
      select_first_match(first, "foo")
      send_search_action(first, {:replace, "bar"})
      assert Buffer.content(first.buffer) == "bar foo foo"
      assert Buffer.cursor(first.buffer) == {0, 4}
      assert_search_stats(first, 2, 1)

      last = start_editor("foo foo foo")
      select_first_match(last, "foo")
      send_search_action(last, :next)
      send_search_action(last, :next)
      assert Buffer.cursor(last.buffer) == {0, 8}
      send_search_action(last, {:replace, "bar"})
      assert Buffer.content(last.buffer) == "foo foo bar"
      assert Buffer.cursor(last.buffer) == {0, 0}
      assert_search_stats(last, 2, 1)

      single = start_editor("foo")
      Buffer.move_to(single.buffer, {0, 2})
      send_search_query(single, "foo")
      send_search_action(single, {:replace, "bar"})
      assert Buffer.content(single.buffer) == "bar"
      assert Buffer.cursor(single.buffer) == {0, 3}
      assert_search_stats(single, 0, 0)
    end

    test "refuses stale query, active buffer, and content targets instead of choosing a nearby match" do
      query = start_editor("foo foo")
      select_first_match(query, "foo")
      send_search_query(query, "missing")
      send_search_action(query, {:replace, "bar"})
      assert Buffer.content(query.buffer) == "foo foo"
      assert notice_message(query) == "Search match changed; select a match and try again"

      buffer = start_editor("foo foo")
      select_first_match(buffer, "foo")
      other = start_supervised!({BufferProcess, content: "x foo"}, id: make_ref())
      replace_active_buffer(buffer, other)
      send_search_action(buffer, {:replace, "bar"})
      assert Buffer.content(other) == "x foo"
      assert notice_message(buffer) == "Search match changed; select a match and try again"

      content = start_editor("foo foo")
      select_first_match(content, "foo")
      :ok = Buffer.replace_content(content.buffer, "x foo")
      send_search_action(content, {:replace, "bar"})
      assert Buffer.content(content.buffer) == "x foo"
      assert notice_message(content) == "Search match changed; select a match and try again"
    end

    test "preserves literal, case, whole-word, regex, Unicode, and zero-width semantics" do
      literal = start_editor("a.b axb")
      Buffer.move_to(literal.buffer, {0, 6})
      send_search_query(literal, "a.b", 0x03)
      send_search_action(literal, {:replace, "literal"})
      assert Buffer.content(literal.buffer) == "literal axb"

      insensitive = start_editor("FOO foo")
      Buffer.move_to(insensitive.buffer, {0, 6})
      send_search_query(insensitive, "foo", 0x01)
      send_search_action(insensitive, {:replace, "bar"})
      assert Buffer.content(insensitive.buffer) == "bar foo"

      sensitive = start_editor("FOO foo")
      Buffer.move_to(sensitive.buffer, {0, 2})
      send_search_query(sensitive, "foo", 0x03)
      send_search_action(sensitive, {:replace, "bar"})
      assert Buffer.content(sensitive.buffer) == "FOO bar"

      whole = start_editor("afoo foo")
      Buffer.move_to(whole.buffer, {0, 7})
      send_search_query(whole, "foo", 0x05)
      send_search_action(whole, {:replace, "bar"})
      assert Buffer.content(whole.buffer) == "afoo bar"

      regex = start_editor("abc123 def")
      Buffer.move_to(regex.buffer, {0, 9})
      send_search_query(regex, "\\d+", 0x0B)
      send_search_action(regex, {:replace, "N"})
      assert Buffer.content(regex.buffer) == "abcN def"

      unicode = start_editor("café café")
      Buffer.move_to(unicode.buffer, {0, 9})
      send_search_query(unicode, "café", 0x03)
      send_search_action(unicode, {:replace, "茶"})
      assert Buffer.content(unicode.buffer) == "茶 café"

      zero_width = start_editor("foo foo")
      Buffer.move_to(zero_width.buffer, {0, 6})
      send_search_query(zero_width, "(?=foo)", 0x0B)
      send_search_action(zero_width, {:replace, "x"})
      assert Buffer.content(zero_width.buffer) == "xfoo foo"
      assert Buffer.cursor(zero_width.buffer) == {0, 5}
      assert_search_stats(zero_width, 2, 2)
    end

    test "creates one exact undo entry and refuses a read-only edit" do
      ctx = start_editor("foo foo foo")
      select_first_match(ctx, "foo")
      send_search_action(ctx, :next)
      send_search_action(ctx, {:replace, "bar"})

      assert BufferProcess.last_undo_source(ctx.buffer) == :user
      assert :ok = Buffer.undo(ctx.buffer)
      assert Buffer.content(ctx.buffer) == "foo foo foo"
      assert Buffer.cursor(ctx.buffer) == {0, 4}
      assert BufferProcess.last_undo_source(ctx.buffer) == nil

      read_only = start_editor("foo foo")
      select_first_match(read_only, "foo")
      version = Buffer.version(read_only.buffer)
      :ok = Buffer.set_read_only(read_only.buffer, true)
      send_search_action(read_only, {:replace, "bar"})
      assert Buffer.content(read_only.buffer) == "foo foo"
      assert Buffer.version(read_only.buffer) == version
      assert notice_message(read_only) == "Buffer is read-only"
    end

    test "keeps rapid toolbar replacements as separate undo units" do
      ctx = start_editor("foo foo foo")
      select_first_match(ctx, "foo")

      send_search_action(ctx, {:replace, "bar"})
      send_search_action(ctx, {:replace, "bar"})
      assert Buffer.content(ctx.buffer) == "bar bar foo"

      assert :ok = Buffer.undo(ctx.buffer)
      assert Buffer.content(ctx.buffer) == "bar foo foo"
      assert Buffer.cursor(ctx.buffer) == {0, 4}
    end

    test "keeps Replace All global and navigation exclusive" do
      ctx = start_editor("foo foo foo")
      select_first_match(ctx, "foo")
      send_search_action(ctx, :next)
      assert Buffer.cursor(ctx.buffer) == {0, 4}

      send_search_action(ctx, {:replace_all, "bar"})
      assert Buffer.content(ctx.buffer) == "bar bar bar"
      assert notice_message(ctx) == "3 replacements"
    end
  end

  defp select_first_match(ctx, query) do
    {line, last_col} = last_match_position(Buffer.content(ctx.buffer), query)
    Buffer.move_to(ctx.buffer, {line, last_col})
    send_search_query(ctx, query)
    assert Buffer.cursor(ctx.buffer) == {0, 0}
  end

  defp last_match_position(content, query) do
    [last | _] = content |> :binary.matches(query) |> Enum.reverse()
    {col, _length} = last
    {0, col}
  end

  defp send_search_query(ctx, query, flags \\ 0x03) do
    payload =
      <<Opcodes.gui_action(), @gui_action_search_query, byte_size(query)::16, query::binary,
        flags::8>>

    send_decoded_gui_action(ctx, payload)
  end

  defp send_search_action(ctx, :next) do
    send_decoded_gui_action(ctx, <<Opcodes.gui_action(), @gui_action_search_next>>)
  end

  defp send_search_action(ctx, {:replace, replacement}) do
    payload =
      <<Opcodes.gui_action(), @gui_action_search_replace, byte_size(replacement)::16,
        replacement::binary>>

    send_decoded_gui_action(ctx, payload)
  end

  defp send_search_action(ctx, {:replace_all, replacement}) do
    payload =
      <<Opcodes.gui_action(), @gui_action_search_replace_all, byte_size(replacement)::16,
        replacement::binary>>

    send_decoded_gui_action(ctx, payload)
  end

  defp send_decoded_gui_action(ctx, payload) do
    assert {:ok, {:gui_action, action}} = Protocol.decode_event(payload)
    send(ctx.editor, {:minga_input, {:gui_action, action}})
    editor_state(ctx)
  end

  defp assert_search_stats(ctx, count, index) do
    model = SearchStateBuilder.build(editor_state(ctx).workspace.search, ctx.buffer)
    assert model.match_count == count
    assert model.current_index == index
  end

  defp replace_active_buffer(ctx, buffer) do
    :sys.replace_state(ctx.editor, fn editor_state ->
      buffers = Buffers.set_active_override(editor_state.workspace.buffers, buffer)
      %{editor_state | workspace: State.set_buffers(editor_state.workspace, buffers)}
    end)
  end
end
