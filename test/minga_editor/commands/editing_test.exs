defmodule MingaEditor.Commands.EditingTest do
  @moduledoc """
  Split editing command coverage by layer.

  Mode FSM tests assert key-to-command emission. Command-state tests assert buffer/register behavior by calling command modules directly. The final describe block keeps a small Editor GenServer smoke layer for end-to-end key routing.
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

  describe "Layer 0 Mode FSM: normal command emission" do
    test "insert entry keys emit commands without a live editor" do
      assert_mode({?i, 0}, :insert, [])
      assert_mode({?a, 0}, :insert, [:move_right])
      assert_mode({?A, 0}, :insert, [:move_to_line_end, :move_right])
      assert_mode({?I, 0}, :insert, [:move_to_line_start])
      assert_mode({?o, 0}, :insert, [:insert_line_below])
      assert_mode({?O, 0}, :insert, [:insert_line_above])
    end

    test "paste and counted delete keys emit normal-mode commands" do
      assert_mode({?p, 0}, :normal, [:paste_after])
      assert_mode({?P, 0}, :normal, [:paste_before])

      {_mode, _commands, counted} = Mode.process(:normal, {?3, 0}, Mode.initial_state())
      {mode, commands, _state} = Mode.process(:normal, {?x, 0}, counted)

      assert mode == :normal
      assert commands == [{:delete_chars_at, 3}]
    end

    test "yy and dd emit operator-pending commands through the FSM" do
      {mode, _commands, pending_yank} = Mode.process(:normal, {?y, 0}, Mode.initial_state())
      assert mode == :operator_pending
      assert pending_yank.operator == :yank

      assert {:normal, [{:yank_lines_counted, 1}], _} =
               Mode.process(:operator_pending, {?y, 0}, pending_yank)

      {mode, _commands, pending_delete} = Mode.process(:normal, {?d, 0}, Mode.initial_state())
      assert mode == :operator_pending
      assert pending_delete.operator == :delete

      assert {:normal, [{:delete_lines_counted, 1}], _} =
               Mode.process(:operator_pending, {?d, 0}, pending_delete)
    end

    test "visual v and V enter visual mode through the FSM" do
      {mode, commands, mode_state} = Mode.process(:normal, {?v, 0}, Mode.initial_state())
      assert mode == :visual
      assert commands == []
      assert mode_state.visual_type == :char

      {mode, commands, mode_state} = Mode.process(:normal, {?V, 0}, Mode.initial_state())
      assert mode == :visual
      assert commands == []
      assert mode_state.visual_type == :line
    end

    test "s emits delete-char and transitions to insert" do
      {mode, commands, _state} = Mode.process(:normal, {?s, 0}, Mode.initial_state())

      assert mode == :insert
      assert commands == [{:delete_chars_at, 1}]
    end
  end

  describe "Layer 0/1 command state: insertion and open-line commands" do
    test "insert_char updates buffer content" do
      buffer = start_buffer("hello")
      state = command_state(buffer)

      _state = Editing.execute(state, {:insert_char, "x"})

      assert BufferProcess.content(buffer) == "xhello"
    end

    test "delete_before and insert_newline mutate content without touching registers" do
      buffer = start_buffer("abc")
      BufferProcess.move_to(buffer, {0, 2})
      state = command_state(buffer)

      state = Editing.execute(state, :delete_before)
      state = Editing.execute(state, :insert_newline)

      assert BufferProcess.content(buffer) == "a\nc"
      assert register_entry(state) == nil
    end

    test "insert_line_below inserts an indented line below" do
      buffer = start_buffer("  hello")
      state = command_state(buffer)

      _state = Editing.execute(state, :insert_line_below)

      assert BufferProcess.content(buffer) == "  hello\n  "
    end

    test "insert_line_above preserves fallback indentation above the first line" do
      buffer = start_buffer("  hello")
      state = command_state(buffer)

      _state = Editing.execute(state, :insert_line_above)
      Editing.execute(state, {:insert_char, "w"})

      assert BufferProcess.content(buffer) == "  w\n  hello"
    end

    test "autopair insert and delete work when command executor is called directly" do
      buffer = start_buffer("")
      BufferProcess.set_option(buffer, :autopair, true)
      state = command_state(buffer)

      _state = Editing.execute(state, {:insert_char, "("})
      assert BufferProcess.content(buffer) == "()"

      _state = Editing.execute(state, :delete_before)
      assert BufferProcess.content(buffer) == ""
    end

    test "insert_char does not autopair inside highlighted strings" do
      buffer = start_buffer("\"hello\"")
      BufferProcess.set_option(buffer, :autopair, true)
      BufferProcess.move_to(buffer, {0, 1})

      highlight =
        Highlight.new()
        |> Highlight.put_names(["string"])
        |> Highlight.put_spans(1, [Span.new(0, 7, 0)])

      _state =
        Editing.execute(command_state_with_highlight(buffer, highlight), {:insert_char, "("})

      assert BufferProcess.content(buffer) == "\"(hello\""
    end

    test "insert_char skips over closing delimiter inside highlighted strings" do
      buffer = start_buffer("\"()\"")
      BufferProcess.set_option(buffer, :autopair, true)
      BufferProcess.move_to(buffer, {0, 2})

      highlight =
        Highlight.new()
        |> Highlight.put_names(["string"])
        |> Highlight.put_spans(1, [Span.new(0, 4, 0)])

      _state =
        Editing.execute(command_state_with_highlight(buffer, highlight), {:insert_char, ")"})

      assert BufferProcess.content(buffer) == "\"()\""
      assert BufferProcess.cursor(buffer) == {0, 3}
    end

    test "insert_char does not autopair opening brackets inside highlighted comments" do
      buffer = start_buffer("# x")
      BufferProcess.set_option(buffer, :autopair, true)
      BufferProcess.move_to(buffer, {0, 2})

      highlight =
        Highlight.new()
        |> Highlight.put_names(["comment"])
        |> Highlight.put_spans(1, [Span.new(0, 3, 0)])

      _state =
        Editing.execute(command_state_with_highlight(buffer, highlight), {:insert_char, "("})

      assert BufferProcess.content(buffer) == "# (x"
    end

    test "insert_char does not autopair at the end of an inline highlighted line comment" do
      buffer = start_buffer("x # comment", filetype: :elixir)
      BufferProcess.set_option(buffer, :autopair, true)
      BufferProcess.move_to(buffer, {0, byte_size("x # comment")})

      highlight =
        Highlight.new()
        |> Highlight.put_names(["comment"])
        |> Highlight.put_spans(1, [Span.new(2, byte_size("x # comment"), 0)])

      _state =
        Editing.execute(command_state_with_highlight(buffer, highlight), {:insert_char, "("})

      assert BufferProcess.content(buffer) == "x # comment("
      assert BufferProcess.cursor(buffer) == {0, byte_size("x # comment(")}
    end

    test "insert_char does not autopair at the end of a no-space line comment" do
      buffer = start_buffer("#x", filetype: :elixir)
      BufferProcess.set_option(buffer, :autopair, true)
      BufferProcess.move_to(buffer, {0, byte_size("#x")})

      highlight =
        Highlight.new()
        |> Highlight.put_names(["comment"])
        |> Highlight.put_spans(1, [Span.new(0, byte_size("#x"), 0)])

      _state =
        Editing.execute(command_state_with_highlight(buffer, highlight), {:insert_char, "("})

      assert BufferProcess.content(buffer) == "#x("
      assert BufferProcess.cursor(buffer) == {0, byte_size("#x(")}
    end
  end

  describe "Layer 0/1 command state: block autopair" do
    test "inserts Elixir end below a block opener and leaves cursor on inner line" do
      buffer = start_buffer("def run do", filetype: :elixir)
      BufferProcess.set_option(buffer, :autopair_block, true)
      BufferProcess.set_option(buffer, :tab_width, 2)
      BufferProcess.set_option(buffer, :indent_with, :spaces)
      BufferProcess.move_to(buffer, {0, byte_size("def run do")})

      _state = Editing.execute(command_state(buffer), :insert_newline)

      assert BufferProcess.content(buffer) == "def run do\n  \nend"
      assert BufferProcess.cursor(buffer) == {1, 2}
    end

    test "does not insert block closer when disabled for the buffer" do
      buffer = start_buffer("def run do", filetype: :elixir)
      BufferProcess.set_option(buffer, :autopair_block, false)
      BufferProcess.move_to(buffer, {0, byte_size("def run do")})

      _state = Editing.execute(command_state(buffer), :insert_newline)

      assert BufferProcess.content(buffer) == "def run do\n"
    end

    test "does not insert block closer when cursor is before trailing text" do
      buffer = start_buffer("def run do rest", filetype: :elixir)
      BufferProcess.set_option(buffer, :autopair_block, true)
      BufferProcess.move_to(buffer, {0, byte_size("def run do")})

      _state = Editing.execute(command_state(buffer), :insert_newline)

      assert BufferProcess.content(buffer) == "def run do\n rest"
    end

    test "insert_newline does not add a block closer at the end of a highlighted line comment" do
      buffer = start_buffer("# def run do", filetype: :elixir)
      BufferProcess.set_option(buffer, :autopair_block, true)
      BufferProcess.move_to(buffer, {0, byte_size("# def run do")})

      highlight =
        Highlight.new()
        |> Highlight.put_names(["comment"])
        |> Highlight.put_spans(1, [Span.new(0, byte_size("# def run do"), 0)])

      _state = Editing.execute(command_state_with_highlight(buffer, highlight), :insert_newline)

      assert BufferProcess.content(buffer) == "# def run do\n"
    end

    test "insert_newline does not add a block closer inside highlighted strings" do
      buffer = start_buffer("def run do", filetype: :elixir)
      BufferProcess.set_option(buffer, :autopair_block, true)
      BufferProcess.move_to(buffer, {0, byte_size("def run do")})

      highlight =
        Highlight.new()
        |> Highlight.put_names(["string"])
        |> Highlight.put_spans(1, [Span.new(0, byte_size("def run do"), 0)])

      _state = Editing.execute(command_state_with_highlight(buffer, highlight), :insert_newline)

      assert BufferProcess.content(buffer) == "def run do\n"
    end
  end

  describe "Layer 0/1 command state: undo, redo, and indent" do
    test "undo and redo operate through direct command execution" do
      buffer = start_buffer("hello")
      state = command_state(buffer)

      state = Editing.execute(state, {:insert_char, "x"})
      assert BufferProcess.content(buffer) == "xhello"

      state = Editing.execute(state, :undo)
      assert BufferProcess.content(buffer) == "hello"

      _state = Editing.execute(state, :redo)
      assert BufferProcess.content(buffer) == "xhello"
    end

    test "indent_line respects tab indentation" do
      buffer = start_buffer("hello")
      BufferProcess.set_option(buffer, :indent_with, :tabs)
      state = command_state(buffer)

      _state = Editing.execute(state, :indent_line)

      assert BufferProcess.content(buffer) == "\thello"
      assert BufferProcess.cursor(buffer) == {0, 1}
    end
  end

  describe "Layer 0/1 command state: linewise paste" do
    test "paste_after and paste_before insert linewise registers as full lines" do
      buffer = start_buffer("aaa\nbbb\nccc")
      state = command_state(buffer) |> with_register("", "aaa\n", :linewise)

      BufferProcess.move_to(buffer, {1, 2})
      _state = Editing.execute(state, :paste_after)
      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nccc"

      buffer = start_buffer("aaa\nbbb")
      state = command_state(buffer) |> with_register("", "bbb\n", :linewise)

      BufferProcess.move_to(buffer, {0, 0})
      _state = Editing.execute(state, :paste_before)
      assert BufferProcess.content(buffer) == "bbb\naaa\nbbb"
    end

    test "linewise paste places cursor on first non-blank of pasted line" do
      buffer = start_buffer("  indented\nplain")
      state = command_state(buffer) |> with_register("", "  indented\n", :linewise)

      BufferProcess.move_to(buffer, {1, 0})
      _state = Editing.execute(state, :paste_after)

      assert BufferProcess.cursor(buffer) == {2, 2}
    end

    test "empty registers leave paste commands as no-ops" do
      buffer = start_buffer("hello")
      original = BufferProcess.content(buffer)
      state = command_state(buffer)

      state = Editing.execute(state, :paste_after)
      _state = Editing.execute(state, :paste_before)

      assert BufferProcess.content(buffer) == original
    end
  end

  describe "Layer 0/1 command state: charwise delete and paste" do
    test "delete_chars_at stores deleted chars and paste_after inserts them inline" do
      buffer = start_buffer("abcdef")
      state = command_state(buffer)

      state = Editing.execute(state, {:delete_chars_at, 3})
      assert BufferProcess.content(buffer) == "def"
      assert register_entry(state) == {"abc", :charwise}

      BufferProcess.move_to(buffer, {0, 2})
      _state = Editing.execute(state, :paste_after)

      assert BufferProcess.content(buffer) == "defabc"
    end

    test "delete_chars_at clamps to available characters" do
      buffer = start_buffer("ab")
      state = command_state(buffer)

      state = Editing.execute(state, {:delete_chars_at, 5})

      assert BufferProcess.content(buffer) == ""
      assert register_entry(state) == {"ab", :charwise}
    end

    test "delete_chars_before stores deleted chars in reading order" do
      buffer = start_buffer("abcdef")
      BufferProcess.move_to(buffer, {0, 4})
      state = command_state(buffer)

      state = Editing.execute(state, {:delete_chars_before, 3})

      assert BufferProcess.content(buffer) == "aef"
      assert register_entry(state) == {"bcd", :charwise}
    end

    test "x on empty line and X at column zero are no-ops" do
      buffer = start_buffer("")
      state = command_state(buffer)

      state = Editing.execute(state, {:delete_chars_at, 1})
      assert BufferProcess.content(buffer) == ""
      assert register_entry(state) == nil

      buffer = start_buffer("abc")
      state = command_state(buffer)

      state = Editing.execute(state, {:delete_chars_before, 1})
      assert BufferProcess.content(buffer) == "abc"
      assert register_entry(state) == nil
    end

    test "named and black-hole registers affect delete behavior" do
      buffer = start_buffer("abc")
      state = command_state(buffer) |> with_active_register("a")

      state = Editing.execute(state, {:delete_chars_at, 1})
      assert BufferProcess.content(buffer) == "bc"
      assert register_entry(state, "a") == {"a", :charwise}

      buffer = start_buffer("abc")

      state =
        command_state(buffer)
        |> with_register("", "seed", :charwise)
        |> with_active_register("_")

      state = Editing.execute(state, {:delete_chars_at, 1})
      assert BufferProcess.content(buffer) == "bc"
      assert register_entry(state) == {"seed", :charwise}
    end
  end

  describe "Layer 0/1 command state: operators, registers, and paste" do
    test "yy then paste_after pastes a yanked line below the target line" do
      buffer = start_buffer("aaa\nbbb\nccc")
      state = command_state(buffer)

      state = Operators.execute(state, {:yank_lines_counted, 1})
      BufferProcess.move_to(buffer, {1, 0})
      _state = Editing.execute(state, :paste_after)

      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nccc"
      assert register_entry(state) == {"aaa\n", :linewise}
      assert register_entry(state, "0") == {"aaa\n", :linewise}
    end

    test "dd then paste_before restores the deleted line above the cursor" do
      buffer = start_buffer("aaa\nbbb\nccc")
      BufferProcess.move_to(buffer, {1, 0})
      state = command_state(buffer)

      state = Operators.execute(state, {:delete_lines_counted, 1})
      _state = Editing.execute(state, :paste_before)

      assert BufferProcess.content(buffer) == "aaa\nbbb\nccc"
      assert register_entry(state) == {"bbb\n", :linewise}
      assert register_entry(state, "0") == nil
    end

    test "cc stores linewise register type before clearing" do
      buffer = start_buffer("hello\nworld")
      state = command_state(buffer)

      state = Operators.execute(state, {:change_lines_counted, 1})

      refute String.contains?(BufferProcess.content(buffer), "hello")
      assert register_entry(state) == {"hello\n", :linewise}
    end

    test "named register preserves linewise type through later unnamed operations" do
      buffer = start_buffer("alpha\nbeta\ngamma")

      state =
        command_state(buffer)
        |> with_active_register("a")
        |> Operators.execute({:yank_lines_counted, 1})

      BufferProcess.move_to(buffer, {1, 0})
      state = Operators.execute(state, {:delete_lines_counted, 1})
      state = with_active_register(state, "a")
      _state = Editing.execute(state, :paste_after)

      assert BufferProcess.content(buffer) == "alpha\ngamma\nalpha"
    end
  end

  describe "Layer 0/1 command state: visual paste contracts" do
    test "visual line yank then paste_after duplicates selected lines" do
      buffer = start_buffer("aaa\nbbb\nccc\nddd")
      BufferProcess.move_to(buffer, {1, 0})
      state = command_state(buffer) |> with_visual_selection({0, 0}, :line)

      state = Visual.execute(state, :yank_visual_selection)
      _state = Editing.execute(state, :paste_after)

      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nbbb\nccc\nddd"
    end

    test "visual line delete then paste_after restores deleted lines as linewise" do
      buffer = start_buffer("aaa\nbbb\nccc")
      BufferProcess.move_to(buffer, {1, 0})
      state = command_state(buffer) |> with_visual_selection({0, 0}, :line)

      state = Visual.execute(state, :delete_visual_selection)
      _state = Editing.execute(state, :paste_after)

      assert BufferProcess.content(buffer) == "ccc\naaa\nbbb"
    end

    test "visual char yank then paste_after stays inline" do
      buffer = start_buffer("abcdefgh")
      BufferProcess.move_to(buffer, {0, 3})
      state = command_state(buffer) |> with_visual_selection({0, 0}, :char)

      state = Visual.execute(state, :yank_visual_selection)
      BufferProcess.move_to(buffer, {0, 7})
      _state = Editing.execute(state, :paste_after)

      assert BufferProcess.content(buffer) == "abcdefghabcd"
    end
  end

  describe "Editor GenServer smoke: key routing" do
    test "normal and insert routing inserts text and Escape returns to normal semantics" do
      {editor, buffer} = start_editor("")

      send_key(editor, ?i)
      Enum.each(~c"abc!", &send_key(editor, &1))
      send_key(editor, 27)
      send_key(editor, ?l)

      assert BufferProcess.content(buffer) == "abc!"
      assert BufferProcess.cursor(buffer) == {0, 3}
    end

    test "operator-pending yy then p routes through the editor" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nccc"
    end

    test "visual v d routes through the editor" do
      {editor, buffer} = start_editor("hello world")
      send_key(editor, ?v)
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?d)

      assert BufferProcess.content(buffer) == "lo world"
    end

    test "command mode key routing enters command mode" do
      {editor, _buffer} = start_editor("hello")
      send_key(editor, ?:)

      assert sync_editor(editor) == :command
    end

    test "paste events route in normal and insert modes" do
      {editor, buffer} = start_editor("start")

      send(editor, {:minga_input, {:paste_event, " normal"}})
      _ = sync_editor(editor)
      send_key(editor, ?i)
      send(editor, {:minga_input, {:paste_event, " insert"}})
      _ = sync_editor(editor)

      content = BufferProcess.content(buffer)
      assert String.contains?(content, "normal")
      assert String.contains?(content, "insert")
    end
  end

  defp assert_mode(key, expected_mode, expected_commands) do
    {mode, commands, _state} = Mode.process(:normal, key, Mode.initial_state())

    assert mode == expected_mode
    assert commands == expected_commands
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
    _ = sync_editor(editor)
  end

  defp sync_editor(editor), do: GenServer.call(editor, :api_mode, @sync_timeout)

  defp command_state_with_highlight(buffer, highlight) do
    state = command_state(buffer)
    workspace = %{state.workspace | highlight: %Highlighting{highlights: %{buffer => highlight}}}
    %{state | workspace: workspace}
  end
end
