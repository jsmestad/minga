defmodule MingaEditor.Commands.EditingTest do
  @moduledoc """
  Boundary-focused coverage for editing commands.
  """

  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Language.Highlight.Span
  alias Minga.Mode
  alias MingaEditor
  alias MingaEditor.Commands.Editing
  alias MingaEditor.Commands.Operators
  alias MingaEditor.Commands.Visual
  alias MingaEditor.State.Highlighting
  alias MingaEditor.UI.Highlight

  @sync_timeout 15_000

  describe "Mode FSM command emission" do
    test "normal keys emit transitions and commands without a live editor" do
      cases = [
        {{?i, 0}, :insert, []},
        {{?a, 0}, :insert, [:move_right]},
        {{?A, 0}, :insert, [:move_to_line_end, :move_right]},
        {{?I, 0}, :insert, [:move_to_line_start]},
        {{?o, 0}, :insert, [:insert_line_below]},
        {{?O, 0}, :insert, [:insert_line_above]},
        {{?s, 0}, :insert, [{:delete_chars_at, 1}]},
        {{?p, 0}, :normal, [:paste_after]},
        {{?P, 0}, :normal, [:paste_before]}
      ]

      for {key, expected_mode, expected_commands} <- cases do
        assert_mode(key, expected_mode, expected_commands)
      end

      {_mode, _commands, counted} = Mode.process(:normal, {?3, 0}, Mode.initial_state())
      assert {:normal, [{:delete_chars_at, 3}], _state} = Mode.process(:normal, {?x, 0}, counted)
    end

    test "operator and visual entry keep modal contracts" do
      for {operator_key, command_key, operator, command} <- [
            {?y, ?y, :yank, {:yank_lines_counted, 1}},
            {?d, ?d, :delete, {:delete_lines_counted, 1}}
          ] do
        {mode, _commands, pending} =
          Mode.process(:normal, {operator_key, 0}, Mode.initial_state())

        assert mode == :operator_pending
        assert pending.operator == operator

        assert {:normal, [^command], _state} =
                 Mode.process(:operator_pending, {command_key, 0}, pending)
      end

      for {key, type} <- [{?v, :char}, {?V, :line}] do
        assert {:visual, [], %{visual_type: ^type}} =
                 Mode.process(:normal, {key, 0}, Mode.initial_state())
      end
    end
  end

  describe "direct editing commands" do
    test "insertion, deletion, open-line, undo, redo, and indent mutate buffers through command execution" do
      buffer = start_buffer("hello")
      Editing.execute(command_state(buffer), {:insert_char, "x"})
      assert BufferProcess.content(buffer) == "xhello"

      buffer = start_buffer("abc")
      BufferProcess.move_to(buffer, {0, 2})
      state = command_state(buffer)
      state = Editing.execute(state, :delete_before)
      Editing.execute(state, :insert_newline)
      assert BufferProcess.content(buffer) == "a\nc"
      assert register_entry(state) == nil

      buffer = start_buffer("  hello")
      Editing.execute(command_state(buffer), :insert_line_below)
      assert BufferProcess.content(buffer) == "  hello\n  "

      buffer = start_buffer("  hello")
      state = command_state(buffer)
      Editing.execute(state, :insert_line_above)
      Editing.execute(state, {:insert_char, "w"})
      assert BufferProcess.content(buffer) == "  w\n  hello"

      buffer = start_buffer("hello")
      state = command_state(buffer)
      state = Editing.execute(state, {:insert_char, "x"})
      assert BufferProcess.content(buffer) == "xhello"
      state = Editing.execute(state, :undo)
      assert BufferProcess.content(buffer) == "hello"
      Editing.execute(state, :redo)
      assert BufferProcess.content(buffer) == "xhello"

      buffer = start_buffer("hello")
      BufferProcess.set_option(buffer, :indent_with, :tabs)
      Editing.execute(command_state(buffer), :indent_line)
      assert BufferProcess.content(buffer) == "\thello"
      assert BufferProcess.cursor(buffer) == {0, 1}
    end

    test "insert_tab inserts indentation at the cursor using buffer tab settings" do
      spaces = start_buffer("ab")
      BufferProcess.set_option(spaces, :tab_width, 4)
      BufferProcess.set_option(spaces, :indent_with, :spaces)
      BufferProcess.move_to(spaces, {0, 2})
      Editing.execute(command_state(spaces), :insert_tab)
      assert BufferProcess.content(spaces) == "ab  "
      assert BufferProcess.cursor(spaces) == {0, 4}

      tabs = start_buffer("ab")
      BufferProcess.set_option(tabs, :indent_with, :tabs)
      BufferProcess.move_to(tabs, {0, 2})
      Editing.execute(command_state(tabs), :insert_tab)
      assert BufferProcess.content(tabs) == "ab\t"
      assert BufferProcess.cursor(tabs) == {0, 3}
    end

    test "autopair pairs, deletes, skips closing delimiters, and suppresses pairing in comments or strings" do
      buffer = start_buffer("")
      BufferProcess.set_option(buffer, :autopair, true)
      state = command_state(buffer)
      Editing.execute(state, {:insert_char, "("})
      assert BufferProcess.content(buffer) == "()"
      Editing.execute(state, :delete_before)
      assert BufferProcess.content(buffer) == ""

      string = highlighted_buffer("\"hello\"", "string", 0, 7, cursor: {0, 1})

      Editing.execute(
        command_state_with_highlight(string, highlight("string", 0, 7)),
        {:insert_char, "("}
      )

      assert BufferProcess.content(string) == "\"(hello\""

      closing = highlighted_buffer("\"()\"", "string", 0, 4, cursor: {0, 2})

      Editing.execute(
        command_state_with_highlight(closing, highlight("string", 0, 4)),
        {:insert_char, ")"}
      )

      assert BufferProcess.content(closing) == "\"()\""
      assert BufferProcess.cursor(closing) == {0, 3}

      comment_cases = [
        {"# x", {0, 2}, 0, 3, "# (x", {0, 3}},
        {"x # comment", {0, byte_size("x # comment")}, 2, byte_size("x # comment"),
         "x # comment(", {0, byte_size("x # comment(")}},
        {"#x", {0, byte_size("#x")}, 0, byte_size("#x"), "#x(", {0, byte_size("#x(")}}
      ]

      for {content, cursor, start_byte, end_byte, expected, expected_cursor} <- comment_cases do
        buffer =
          highlighted_buffer(content, "comment", start_byte, end_byte,
            cursor: cursor,
            filetype: :elixir
          )

        Editing.execute(
          command_state_with_highlight(buffer, highlight("comment", start_byte, end_byte)),
          {:insert_char, "("}
        )

        assert BufferProcess.content(buffer) == expected
        assert BufferProcess.cursor(buffer) == expected_cursor
      end
    end

    test "block autopair inserts closers only for enabled code at the end of a block opener" do
      enabled = start_buffer("def run do", filetype: :elixir)
      BufferProcess.set_option(enabled, :autopair_block, true)
      BufferProcess.set_option(enabled, :tab_width, 2)
      BufferProcess.set_option(enabled, :indent_with, :spaces)
      BufferProcess.move_to(enabled, {0, byte_size("def run do")})
      Editing.execute(command_state(enabled), :insert_newline)
      assert BufferProcess.content(enabled) == "def run do\n  \nend"
      assert BufferProcess.cursor(enabled) == {1, 2}

      cases = [
        {start_buffer("def run do", filetype: :elixir), false, {0, byte_size("def run do")}, nil,
         "def run do\n"},
        {start_buffer("def run do rest", filetype: :elixir), true, {0, byte_size("def run do")},
         nil, "def run do\n rest"},
        {start_buffer("# def run do", filetype: :elixir), true, {0, byte_size("# def run do")},
         "comment", "# def run do\n"},
        {start_buffer("def run do", filetype: :elixir), true, {0, byte_size("def run do")},
         "string", "def run do\n"}
      ]

      for {buffer, autopair_block, cursor, capture, expected} <- cases do
        BufferProcess.set_option(buffer, :autopair_block, autopair_block)
        BufferProcess.move_to(buffer, cursor)

        state =
          if capture == nil do
            command_state(buffer)
          else
            command_state_with_highlight(buffer, highlight(capture, 0, elem(cursor, 1)))
          end

        Editing.execute(state, :insert_newline)
        assert BufferProcess.content(buffer) == expected
      end
    end
  end

  describe "register, paste, operator, and visual contracts" do
    test "linewise paste inserts full lines, positions the cursor, and ignores empty registers" do
      buffer = start_buffer("aaa\nbbb\nccc")
      state = command_state(buffer) |> with_register("", "aaa\n", :linewise)
      BufferProcess.move_to(buffer, {1, 2})
      Editing.execute(state, :paste_after)
      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nccc"

      buffer = start_buffer("aaa\nbbb")
      state = command_state(buffer) |> with_register("", "bbb\n", :linewise)
      BufferProcess.move_to(buffer, {0, 0})
      Editing.execute(state, :paste_before)
      assert BufferProcess.content(buffer) == "bbb\naaa\nbbb"

      buffer = start_buffer("  indented\nplain")
      state = command_state(buffer) |> with_register("", "  indented\n", :linewise)
      BufferProcess.move_to(buffer, {1, 0})
      Editing.execute(state, :paste_after)
      assert BufferProcess.cursor(buffer) == {2, 2}

      buffer = start_buffer("hello")
      state = command_state(buffer)
      state = Editing.execute(state, :paste_after)
      Editing.execute(state, :paste_before)
      assert BufferProcess.content(buffer) == "hello"
    end

    test "charwise deletes clamp, preserve deleted text order, paste inline, and honor named registers" do
      buffer = start_buffer("abcdef")
      state = command_state(buffer)
      state = Editing.execute(state, {:delete_chars_at, 3})
      assert BufferProcess.content(buffer) == "def"
      assert register_entry(state) == {"abc", :charwise}
      BufferProcess.move_to(buffer, {0, 2})
      Editing.execute(state, :paste_after)
      assert BufferProcess.content(buffer) == "defabc"

      buffer = start_buffer("ab")
      state = command_state(buffer) |> Editing.execute({:delete_chars_at, 5})
      assert BufferProcess.content(buffer) == ""
      assert register_entry(state) == {"ab", :charwise}

      buffer = start_buffer("abcdef")
      BufferProcess.move_to(buffer, {0, 4})
      state = command_state(buffer) |> Editing.execute({:delete_chars_before, 3})
      assert BufferProcess.content(buffer) == "aef"
      assert register_entry(state) == {"bcd", :charwise}

      buffer = start_buffer("")
      state = command_state(buffer) |> Editing.execute({:delete_chars_at, 1})
      assert BufferProcess.content(buffer) == ""
      assert register_entry(state) == nil

      buffer = start_buffer("abc")
      state = command_state(buffer) |> Editing.execute({:delete_chars_before, 1})
      assert BufferProcess.content(buffer) == "abc"
      assert register_entry(state) == nil

      buffer = start_buffer("abc")

      state =
        command_state(buffer)
        |> with_active_register("a")
        |> Editing.execute({:delete_chars_at, 1})

      assert BufferProcess.content(buffer) == "bc"
      assert register_entry(state, "a") == {"a", :charwise}

      buffer = start_buffer("abc")

      state =
        command_state(buffer)
        |> with_register("", "seed", :charwise)
        |> with_active_register("_")
        |> Editing.execute({:delete_chars_at, 1})

      assert BufferProcess.content(buffer) == "bc"
      assert register_entry(state) == {"seed", :charwise}
    end

    test "line operators preserve yank/delete/change register semantics through paste" do
      buffer = start_buffer("aaa\nbbb\nccc")
      state = command_state(buffer) |> Operators.execute({:yank_lines_counted, 1})
      BufferProcess.move_to(buffer, {1, 0})
      Editing.execute(state, :paste_after)
      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nccc"
      assert register_entry(state) == {"aaa\n", :linewise}
      assert register_entry(state, "0") == {"aaa\n", :linewise}

      buffer = start_buffer("aaa\nbbb\nccc")
      BufferProcess.move_to(buffer, {1, 0})
      state = command_state(buffer) |> Operators.execute({:delete_lines_counted, 1})
      Editing.execute(state, :paste_before)
      assert BufferProcess.content(buffer) == "aaa\nbbb\nccc"
      assert register_entry(state) == {"bbb\n", :linewise}
      assert register_entry(state, "0") == nil

      buffer = start_buffer("hello\nworld")
      state = command_state(buffer) |> Operators.execute({:change_lines_counted, 1})
      refute String.contains?(BufferProcess.content(buffer), "hello")
      assert register_entry(state) == {"hello\n", :linewise}

      buffer = start_buffer("alpha\nbeta\ngamma")

      state =
        command_state(buffer)
        |> with_active_register("a")
        |> Operators.execute({:yank_lines_counted, 1})

      BufferProcess.move_to(buffer, {1, 0})
      state = Operators.execute(state, {:delete_lines_counted, 1})
      state = with_active_register(state, "a")
      Editing.execute(state, :paste_after)
      assert BufferProcess.content(buffer) == "alpha\ngamma\nalpha"
    end

    test "visual line and char operations preserve linewise versus inline paste behavior" do
      buffer = start_buffer("aaa\nbbb\nccc\nddd")
      BufferProcess.move_to(buffer, {1, 0})

      state =
        command_state(buffer)
        |> with_visual_selection({0, 0}, :line)
        |> Visual.execute(:yank_visual_selection)

      Editing.execute(state, :paste_after)
      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nbbb\nccc\nddd"

      buffer = start_buffer("aaa\nbbb\nccc")
      BufferProcess.move_to(buffer, {1, 0})

      state =
        command_state(buffer)
        |> with_visual_selection({0, 0}, :line)
        |> Visual.execute(:delete_visual_selection)

      Editing.execute(state, :paste_after)
      assert BufferProcess.content(buffer) == "ccc\naaa\nbbb"

      buffer = start_buffer("abcdefgh")
      BufferProcess.move_to(buffer, {0, 3})

      state =
        command_state(buffer)
        |> with_visual_selection({0, 0}, :char)
        |> Visual.execute(:yank_visual_selection)

      BufferProcess.move_to(buffer, {0, 7})
      Editing.execute(state, :paste_after)
      assert BufferProcess.content(buffer) == "abcdefghabcd"
    end
  end

  describe "Editor GenServer smoke layer" do
    test "key routing covers insert, operator, visual, command, and paste paths" do
      {editor, buffer} = start_editor("")
      assert send_key(editor, ?i) == :insert
      assert send_key(editor, ?a) == :insert
      assert BufferProcess.content(buffer) == "a"
      assert send_key(editor, ?b) == :insert
      assert BufferProcess.content(buffer) == "ab"
      assert send_key(editor, ?c) == :insert
      assert BufferProcess.content(buffer) == "abc"
      assert send_key(editor, ?!) == :insert
      assert BufferProcess.content(buffer) == "abc!"
      assert send_key(editor, 27) == :normal
      send_key(editor, ?l)
      assert BufferProcess.content(buffer) == "abc!"
      assert BufferProcess.cursor(buffer) == {0, 3}

      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      Enum.each([?y, ?y, ?j, ?p], &send_key(editor, &1))
      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nccc"

      {editor, buffer} = start_editor("hello world")
      Enum.each([?v, ?l, ?l, ?d], &send_key(editor, &1))
      assert BufferProcess.content(buffer) == "lo world"

      {editor, _buffer} = start_editor("hello")
      send_key(editor, ?:)
      assert sync_editor(editor) == :command

      {editor, buffer} = start_editor("start")
      send(editor, {:minga_input, {:paste_event, " normal"}})
      sync_editor(editor)
      send_key(editor, ?i)
      send(editor, {:minga_input, {:paste_event, " insert"}})
      sync_editor(editor)
      assert BufferProcess.content(buffer) =~ "normal"
      assert BufferProcess.content(buffer) =~ "insert"
    end
  end

  defp assert_mode(key, expected_mode, expected_commands) do
    {mode, commands, _state} = Mode.process(:normal, key, Mode.initial_state())

    assert mode == expected_mode
    assert commands == expected_commands
  end

  defp highlighted_buffer(content, capture, start_byte, end_byte, opts) do
    buffer = start_buffer(content, filetype: Keyword.get(opts, :filetype, :text))
    BufferProcess.set_option(buffer, :autopair, true)
    BufferProcess.move_to(buffer, Keyword.fetch!(opts, :cursor))
    _ = highlight(capture, start_byte, end_byte)
    buffer
  end

  defp highlight(capture, start_byte, end_byte) do
    Highlight.new()
    |> Highlight.put_names([capture])
    |> Highlight.put_spans(1, [Span.new(start_byte, end_byte, 0)])
  end

  defp start_editor(content) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"editing_test_events_#{id}"
    {:ok, _events} = Registry.start_link(keys: :duplicate, name: events_registry)
    {:ok, options_server} = Options.start_link(name: nil)
    {:ok, _} = Options.set(options_server, :clipboard, :none)
    {:ok, keymap_server} = KeymapActive.start_link(name: nil)
    {:ok, buffer} = BufferProcess.start_link(content: content, events_registry: events_registry)
    BufferProcess.set_option(buffer, :clipboard, :none)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{id}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10,
        editing_model: :vim,
        events_registry: events_registry,
        keymap_server: keymap_server,
        options_server: options_server
      )

    {editor, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    sync_editor(editor)
  end

  defp sync_editor(editor), do: GenServer.call(editor, :api_mode, @sync_timeout)

  defp command_state_with_highlight(buffer, highlight) do
    state = command_state(buffer)
    workspace = %{state.workspace | highlight: %Highlighting{highlights: %{buffer => highlight}}}
    %{state | workspace: workspace}
  end
end
