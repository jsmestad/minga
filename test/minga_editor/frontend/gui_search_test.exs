defmodule MingaEditor.Frontend.GUISearchTest do
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Search.Index
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.RenderModel.UI.SearchStateBuilder
  alias MingaEditor.RenderPipeline.Intent
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
  @gui_action_search_focus Opcodes.gui_action_search_focus()

  # ── decode_gui_action ──

  describe "decode_gui_action for search_query" do
    test "decodes query with flags" do
      payload = <<7::32, 3::32, 5::16, "hello"::binary, 0x02::8>>

      assert {:ok, {:search_query, 7, 3, "hello", 2}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_query, payload)
    end

    test "decodes empty query" do
      payload = <<1::32, 1::32, 0::16, 0x00::8>>

      assert {:ok, {:search_query, 1, 1, "", 0}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_query, payload)
    end

    test "decodes query with all flags set" do
      payload = <<2::32, 9::32, 3::16, "foo"::binary, 0x0E::8>>

      assert {:ok, {:search_query, 2, 9, "foo", 0x0E}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_query, payload)
    end

    test "decodes non-ASCII query" do
      query = "café"
      len = byte_size(query)
      payload = <<11::32, 4::32, len::16, query::binary, 0x00::8>>

      assert {:ok, {:search_query, 11, 4, ^query, 0}} =
               ProtocolGUI.decode_gui_action(@gui_action_search_query, payload)
    end

    test "returns error for truncated payload" do
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_search_query, <<0, 5, "hi">>)
    end

    test "returns error for empty payload" do
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_search_query, <<>>)
    end
  end

  describe "decode_gui_action for search_focus" do
    test "decodes Find and Replace focus modes" do
      assert {:ok, {:search_focus, false}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_focus, <<0>>)

      assert {:ok, {:search_focus, true}} ==
               ProtocolGUI.decode_gui_action(@gui_action_search_focus, <<1>>)
    end

    test "rejects invalid booleans and payload lengths" do
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_search_focus, <<2>>)
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_search_focus, <<>>)
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_search_focus, <<0, 0>>)
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
      binary =
        <<@op_gui_action, @gui_action_search_query, 4::32, 2::32, 3::16, "foo"::binary, 0x02>>

      assert {:ok, {:gui_action, {:search_query, 4, 2, "foo", 2}}} ==
               MingaEditor.Frontend.Protocol.decode_event(binary)
    end

    test "decodes a complete search_focus event" do
      binary = <<@op_gui_action, @gui_action_search_focus, 1>>

      assert {:ok, {:gui_action, {:search_focus, true}}} ==
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
    test "focus starts a complete search session from the last pattern" do
      result = SearchData.focus_gui_search(%SearchData{last_pattern: "foo"}, true)

      assert %MingaEditor.State.Search.Session{
               active: true,
               session_id: 1,
               acknowledged_edit_seq: 0,
               query: "foo",
               replace_mode: true,
               case_sensitive: false,
               whole_word: false,
               regex: false,
               result: :loading
             } = result.gui_search
    end

    test "repeated focus preserves query and options while changing mode and session" do
      s = SearchData.focus_gui_search(%SearchData{}, false)
      {:accepted, s} = SearchData.apply_gui_search_edit(s, 1, 1, "foo", true, true, false)
      result = SearchData.focus_gui_search(s, true)

      assert %MingaEditor.State.Search.Session{
               active: true,
               session_id: 2,
               acknowledged_edit_seq: 0,
               query: "foo",
               replace_mode: true,
               case_sensitive: true,
               whole_word: true,
               regex: false,
               result: :loading
             } = result.gui_search
    end

    test "accepts only newer edits for the active session" do
      s = SearchData.focus_gui_search(%SearchData{}, false)
      {:accepted, newer} = SearchData.apply_gui_search_edit(s, 1, 2, "B", true, false, false)
      assert newer.last_pattern == "B"
      assert newer.gui_search.acknowledged_edit_seq == 2
      assert newer.gui_search.case_sensitive

      assert {:stale, ^newer} =
               SearchData.apply_gui_search_edit(newer, 1, 1, "A", false, true, true)

      assert {:stale, ^newer} =
               SearchData.apply_gui_search_edit(newer, 7, 3, "old session", false, false, false)
    end

    test "gui_search_active? returns true only for an active retained session" do
      s = SearchData.focus_gui_search(%SearchData{}, false)
      assert SearchData.gui_search_active?(s)
      refute s |> SearchData.dismiss_gui_search() |> SearchData.gui_search_active?()
      refute SearchData.gui_search_active?(%SearchData{})
    end

    test "dismiss retains query and options for a fresh reopen session" do
      s = SearchData.focus_gui_search(%SearchData{}, false)
      {:accepted, s} = SearchData.apply_gui_search_edit(s, 1, 1, "hello", true, false, true)
      result = SearchData.dismiss_gui_search(s)
      refute result.gui_search.active
      assert result.gui_search.query == "hello"

      reopened = SearchData.focus_gui_search(result, true)
      assert reopened.gui_search.session_id == 2
      assert reopened.gui_search.acknowledged_edit_seq == 0
      assert reopened.gui_search.query == "hello"
      assert reopened.gui_search.case_sensitive
      assert reopened.gui_search.regex
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
    test "cursor-only frame intents reuse the accepted index without matching work" do
      ctx = start_editor(Enum.join(List.duplicate("foo and text", 2_000), "\n"))
      send_search_query(ctx, "foo")

      before = ready_index(ctx)
      before_metrics = Index.metrics(before)

      for col <- 0..20 do
        Buffer.move_to(ctx.buffer, {0, col})
        intent = Intent.from_editor_state(editor_state(ctx))
        assert intent.workspace.search.match_count == 2_000
        refute Map.has_key?(Map.from_struct(intent.workspace.search), :root)
      end

      assert Index.metrics(ready_index(ctx)) == before_metrics
    end

    test "line-local edits scan only affected current lines and undo rebuilds exactly" do
      ctx = start_editor("foo\nnone\nfoo")
      send_search_query(ctx, "foo")
      initial_metrics = Index.metrics(ready_index(ctx))

      Buffer.move_to(ctx.buffer, {1, 0})
      :ok = Buffer.insert_text(ctx.buffer, "foo")
      {_version, sequence} = Buffer.sync_revision(ctx.buffer)

      wait_until(ctx, fn state ->
        match?(
          %{accepted_sequence: ^sequence, result: {:ready, _index}},
          state.workspace.search.gui_search
        )
      end)

      updated = ready_index(ctx)
      assert Index.count(updated) == 3
      assert Index.metrics(updated).scanned_lines == initial_metrics.scanned_lines + 1
      assert Index.metrics(updated).updated_lines == 1

      :ok = Buffer.undo(ctx.buffer)
      {undo_version, undo_sequence} = Buffer.sync_revision(ctx.buffer)

      wait_until(ctx, fn state ->
        match?(
          %{
            accepted_version: ^undo_version,
            accepted_sequence: ^undo_sequence,
            result: {:ready, _index}
          },
          state.workspace.search.gui_search
        )
      end)

      assert Index.count(ready_index(ctx)) == 2
    end

    test "uses the exact committed Unicode query and options for actions" do
      ctx = start_editor("CAFÉ café")
      send_search_focus(ctx, true)
      send_search_query(ctx, "café", 0x02)

      send_search_action(ctx, {:replace_all, "résumé"})

      assert Buffer.content(ctx.buffer) == "CAFÉ résumé"
    end

    test "Find to Replace preserves the visible query and options used by replacement" do
      ctx = start_editor("FOO foo")
      Buffer.move_to(ctx.buffer, {0, 6})
      send_search_focus(ctx, false)
      send_search_query(ctx, "foo", 0x02)
      find_session = editor_state(ctx).workspace.search.gui_search.session_id

      send_search_focus(ctx, true)
      search = editor_state(ctx).workspace.search.gui_search
      assert search.session_id == find_session + 1
      assert search.query == "foo"
      assert search.case_sensitive
      assert search.replace_mode
      assert match?({:ready, %Index{}}, search.result)

      send_search_action(ctx, {:replace, "bar"})
      assert Buffer.content(ctx.buffer) == "FOO bar"
    end

    test "delayed query and option echoes cannot overwrite a newer edit" do
      ctx = start_editor("A B")
      send_search_focus(ctx, false)
      session_id = editor_state(ctx).workspace.search.gui_search.session_id

      send_search_edit(ctx, session_id, 1, "A", 0x02)
      send_search_edit(ctx, session_id, 2, "B", 0x04)
      send_search_edit(ctx, session_id, 1, "A", 0x08)

      search = editor_state(ctx).workspace.search.gui_search
      assert search.query == "B"
      refute search.case_sensitive
      assert search.whole_word
      refute search.regex
      assert search.acknowledged_edit_seq == 2
    end

    test "acknowledges the visible query even when no buffer is active" do
      ctx = start_editor("content")
      send_search_focus(ctx, false)
      session_id = editor_state(ctx).workspace.search.gui_search.session_id
      replace_active_buffer(ctx, nil)

      send_search_edit(ctx, session_id, 1, "café", 0x08)

      search = editor_state(ctx).workspace.search.gui_search
      assert search.query == "café"
      assert search.regex
      assert search.acknowledged_edit_seq == 1
    end

    test "a closed and reopened session rejects an old session edit" do
      ctx = start_editor("old new")
      send_search_focus(ctx, false)
      old_session_id = editor_state(ctx).workspace.search.gui_search.session_id
      send_search_edit(ctx, old_session_id, 1, "old", 0)
      send_decoded_gui_action(ctx, <<Opcodes.gui_action(), @gui_action_search_dismiss>>)
      send_search_focus(ctx, false)

      new_session_id = editor_state(ctx).workspace.search.gui_search.session_id
      assert new_session_id != old_session_id
      send_search_edit(ctx, old_session_id, 2, "stale", 0x0E)

      search = editor_state(ctx).workspace.search.gui_search
      assert search.session_id == new_session_id
      assert search.query == "old"
      refute search.case_sensitive
      refute search.whole_word
      refute search.regex
    end

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

      assert notice_message(query) ==
               "Search results changed; wait for Find to finish and try again"

      buffer = start_editor("foo foo")
      select_first_match(buffer, "foo")
      other = start_supervised!({BufferProcess, content: "x foo"}, id: make_ref())
      replace_active_buffer(buffer, other)
      send_search_action(buffer, {:replace, "bar"})
      assert Buffer.content(other) == "x foo"

      assert notice_message(buffer) ==
               "Search results changed; wait for Find to finish and try again"

      content = start_editor("foo foo")
      select_first_match(content, "foo")
      :ok = Buffer.replace_content(content.buffer, "x foo")
      send_search_action(content, {:replace, "bar"})
      assert Buffer.content(content.buffer) == "x foo"

      assert notice_message(content) ==
               "Search results changed; wait for Find to finish and try again"
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
    unless SearchData.gui_search_active?(editor_state(ctx).workspace.search) do
      send_search_focus(ctx, false)
    end

    search = editor_state(ctx).workspace.search.gui_search
    send_search_edit(ctx, search.session_id, search.acknowledged_edit_seq + 1, query, flags)
  end

  defp send_search_edit(ctx, session_id, edit_seq, query, flags) do
    payload =
      <<Opcodes.gui_action(), @gui_action_search_query, session_id::32, edit_seq::32,
        byte_size(query)::16, query::binary, flags::8>>

    send_decoded_gui_action(ctx, payload)

    state = editor_state(ctx)

    if is_pid(state.workspace.buffers.active) and
         state.workspace.search.gui_search.acknowledged_edit_seq == edit_seq do
      wait_until(ctx, &search_edit_ready?(&1, edit_seq))
    end
  end

  defp search_edit_ready?(state, edit_seq) do
    match?(
      %{acknowledged_edit_seq: ^edit_seq, result: {:ready, _index}},
      state.workspace.search.gui_search
    )
  end

  defp send_search_focus(ctx, replace_mode) do
    replace_mode_byte = if replace_mode, do: 1, else: 0

    send_decoded_gui_action(
      ctx,
      <<Opcodes.gui_action(), @gui_action_search_focus, replace_mode_byte>>
    )
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
    state = editor_state(ctx)

    projection =
      SearchData.render_snapshot(state.workspace.search, ctx.buffer, Buffer.cursor(ctx.buffer))

    model = SearchStateBuilder.build(projection)
    assert model.match_count == count
    assert model.current_index == index
  end

  defp ready_index(ctx) do
    state = editor_state(ctx)
    revision = Buffer.sync_revision(ctx.buffer)
    assert {:ok, index} = SearchData.ready_gui_index(state.workspace.search, ctx.buffer, revision)
    index
  end

  defp replace_active_buffer(ctx, buffer) do
    :sys.replace_state(ctx.editor, fn editor_state ->
      buffers = Buffers.set_active_override(editor_state.workspace.buffers, buffer)
      %{editor_state | workspace: State.set_buffers(editor_state.workspace, buffers)}
    end)
  end
end
