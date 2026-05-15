defmodule MingaEditor.Commands.EditingTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Keymap.Active, as: KeymapActive
  alias MingaEditor

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
    _ = :sys.get_state(editor)
  end

  describe "Normal → Insert transition" do
    test "i enters insert mode and allows character insertion" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)

      assert BufferProcess.content(buffer) == "xhello"
    end

    test "a moves right and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?a)
      send_key(editor, ?x)

      assert String.contains?(BufferProcess.content(buffer), "x")
    end

    test "A moves after line end and enters insert mode" do
      {editor, buffer} = start_editor("hi")
      send_key(editor, ?A)
      send_key(editor, ?!)

      assert BufferProcess.content(buffer) == "hi!"
    end

    test "I moves to line start and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?I)
      send_key(editor, ?^)

      assert String.starts_with?(BufferProcess.content(buffer), "^")
    end

    test "o inserts a new line below and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?o)
      send_key(editor, ?w)

      content = BufferProcess.content(buffer)
      assert String.contains?(content, "\n")
      assert String.contains?(content, "w")
    end

    test "O inserts a new line above and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?O)
      send_key(editor, ?w)

      content = BufferProcess.content(buffer)
      assert String.contains?(content, "\n")
      assert String.contains?(content, "w")
    end

    test "O above an indented first line preserves fallback indentation" do
      {editor, buffer} = start_editor("  hello")
      send_key(editor, ?O)
      send_key(editor, ?w)

      assert BufferProcess.content(buffer) == "  w\n  hello"
    end
  end

  describe "Insert mode operations" do
    test "insert character updates buffer" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?i)
      send_key(editor, ?x)

      assert BufferProcess.content(buffer) == "xhello\nworld\nfoo"
    end

    test "backspace (127) deletes character in insert mode" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?i)
      send_key(editor, ?a)
      _ = :sys.get_state(editor)
      send_key(editor, 127)

      assert BufferProcess.content(buffer) == "hello\nworld\nfoo"
    end

    test "enter inserts newline in insert mode" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?i)
      send_key(editor, 13)

      assert BufferProcess.content(buffer) == "\nhello\nworld\nfoo"
    end
  end

  describe "Insert → Normal transition" do
    test "Escape returns to Normal mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)
      send_key(editor, 27)

      content_before = BufferProcess.content(buffer)
      send_key(editor, ?l)
      assert BufferProcess.content(buffer) == content_before
    end

    test "Escape from insert at end of line leaves normal cursor on the inserted character" do
      {editor, buffer} = start_editor("")

      send_key(editor, ?i)
      Enum.each(~c"abc!", &send_key(editor, &1))
      send_key(editor, 27)

      assert BufferProcess.content(buffer) == "abc!"
      assert BufferProcess.cursor(buffer) == {0, 3}
    end

    test "visual round trip after insert preserves normal cursor semantics for the next insert" do
      {editor, buffer} = start_editor("")

      send_key(editor, ?i)
      Enum.each(~c"abc!", &send_key(editor, &1))
      send_key(editor, 27)
      send_key(editor, ?v)
      send_key(editor, 27)
      send_key(editor, ?i)
      send_key(editor, ?X)

      assert BufferProcess.content(buffer) == "abcX!"
    end
  end

  describe "undo / redo" do
    test "u undoes the last change" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)
      send_key(editor, 27)

      assert BufferProcess.content(buffer) == "xhello"
      send_key(editor, ?u)
      assert BufferProcess.content(buffer) == "hello"
    end

    test "Ctrl+r redoes after undo" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)
      send_key(editor, 27)

      send_key(editor, ?u)
      assert BufferProcess.content(buffer) == "hello"

      send_key(editor, ?r, 0x02)
      assert BufferProcess.content(buffer) == "xhello"
    end
  end

  describe "paste operations" do
    test "p pastes after cursor" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      content = BufferProcess.content(buffer)
      assert String.contains?(content, "hello")
      lines = String.split(content, "\n")
      assert length(lines) >= 3
    end

    test "P pastes before cursor" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?P)

      assert String.contains?(BufferProcess.content(buffer), "hello")
    end

    test "p is a no-op when register is empty" do
      {editor, buffer} = start_editor("hello")
      original = BufferProcess.content(buffer)
      send_key(editor, ?p)
      assert BufferProcess.content(buffer) == original
    end

    test "P is a no-op when register is empty" do
      {editor, buffer} = start_editor("hello")
      original = BufferProcess.content(buffer)
      send_key(editor, ?P)
      assert BufferProcess.content(buffer) == original
    end
  end

  # ── Linewise paste ──────────────────────────────────────────────────────

  describe "linewise paste (yy + p)" do
    test "yy then p pastes yanked line below the current line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nccc"
    end

    test "yy then P pastes yanked line above the current line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      # move to line 2, paste above
      send_key(editor, ?j)
      send_key(editor, ?j)
      send_key(editor, ?P)

      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nccc"
    end

    test "p on the last line of the file appends a new line" do
      {editor, buffer} = start_editor("aaa\nbbb")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa"
    end

    test "P on the first line of the file inserts above" do
      {editor, buffer} = start_editor("aaa\nbbb")
      BufferProcess.move_to(buffer, {1, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?P)

      assert BufferProcess.content(buffer) == "bbb\naaa\nbbb"
    end

    test "cursor column is irrelevant for linewise paste" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      # move to middle of line 1
      BufferProcess.move_to(buffer, {1, 2})
      send_key(editor, ?p)

      # Should still paste as a full new line, not splice at col 2
      assert BufferProcess.content(buffer) == "aaa\nbbb\naaa\nccc"
    end
  end

  describe "indent commands" do
    test ">> respects tab indentation" do
      {editor, buffer} = start_editor("hello")
      BufferProcess.set_option(buffer, :indent_with, :tabs)

      send_key(editor, ?>)
      send_key(editor, ?>)

      assert BufferProcess.content(buffer) == "\thello"
      assert BufferProcess.cursor(buffer) == {0, 1}
    end
  end

  describe "linewise paste (dd + p/P)" do
    test "dd then p moves deleted line below current line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?d)
      send_key(editor, ?d)
      send_key(editor, ?p)

      assert BufferProcess.content(buffer) == "bbb\naaa\nccc"
    end

    test "dd then P pastes deleted line above current line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferProcess.move_to(buffer, {1, 0})
      send_key(editor, ?d)
      send_key(editor, ?d)
      # cursor is now on "ccc"
      send_key(editor, ?P)

      assert BufferProcess.content(buffer) == "aaa\nbbb\nccc"
    end
  end

  describe "linewise paste cursor positioning" do
    test "p lands cursor on first non-blank of pasted line" do
      {editor, buffer} = start_editor("  indented\nplain")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      {line, col} = BufferProcess.cursor(buffer)
      assert line == 2
      assert col == 2
    end

    test "P lands cursor on first non-blank of pasted line" do
      {editor, buffer} = start_editor("plain\n    deep")
      BufferProcess.move_to(buffer, {1, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?P)

      {line, col} = BufferProcess.cursor(buffer)
      assert line == 0
      assert col == 4
    end

    test "p with no-indent line lands cursor at col 0" do
      {editor, buffer} = start_editor("noindent\nother")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      # Cross-process barrier: confirm `j` has fully landed in BufferProcess
      # before we paste. `send_key`'s `:sys.get_state(editor)` only proves
      # the editor process drained its mailbox, not that any async follow-up
      # work the executor scheduled has applied to BufferProcess state.
      _ = BufferProcess.cursor(buffer)
      send_key(editor, ?p)

      {line, col} = BufferProcess.cursor(buffer)
      assert line == 2
      assert col == 0
    end
  end

  describe "cc stores linewise register type" do
    test "cc yanks the line content as linewise before clearing" do
      {editor, _buffer} = start_editor("hello\nworld")
      send_key(editor, ?c)
      send_key(editor, ?c)

      s = :sys.get_state(editor)
      assert Map.get(s.workspace.editing.reg.registers, "") == {"hello\n", :linewise}
    end
  end

  # ── Charwise paste (regression guard) ──────────────────────────────────

  describe "charwise paste stays inline" do
    test "yw then p pastes inline, no new line created" do
      {editor, buffer} = start_editor("hello world")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?w)
      send_key(editor, ?$)
      send_key(editor, ?p)

      content = BufferProcess.content(buffer)
      refute String.contains?(content, "\n")
    end

    test "x then p pastes deleted char inline" do
      {editor, buffer} = start_editor("abc")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?x)
      assert BufferProcess.content(buffer) == "bc"

      send_key(editor, ?p)
      assert BufferProcess.content(buffer) == "bac"
    end

    test "dw then p pastes deleted word inline" do
      {editor, buffer} = start_editor("one two three")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?d)
      send_key(editor, ?w)
      # "one " deleted, cursor at "two"
      send_key(editor, ?$)
      send_key(editor, ?p)

      content = BufferProcess.content(buffer)
      refute String.contains?(content, "\n")
      assert String.contains?(content, "one ")
    end
  end

  # ── Named register linewise round-trip ─────────────────────────────────

  describe "named register linewise round-trip" do
    test ~S["ayy then "ap pastes as a new line] do
      {editor, buffer} = start_editor("first\nsecond\nthird")
      BufferProcess.move_to(buffer, {0, 0})
      # "ayy
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?y)
      send_key(editor, ?y)
      # move to last line, "ap
      send_key(editor, ?j)
      send_key(editor, ?j)
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?p)

      assert BufferProcess.content(buffer) == "first\nsecond\nthird\nfirst"
    end

    test "named register preserves linewise type through multiple operations" do
      {editor, buffer} = start_editor("alpha\nbeta\ngamma")
      BufferProcess.move_to(buffer, {0, 0})
      # "ayy
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?y)
      send_key(editor, ?y)
      # Now do an unnamed dd (overwrites unnamed register, not "a")
      send_key(editor, ?j)
      send_key(editor, ?d)
      send_key(editor, ?d)
      # "ap should still paste "alpha" as linewise from register a
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?p)

      assert BufferProcess.content(buffer) == "alpha\ngamma\nalpha"
    end
  end

  # ── Visual-line paste ──────────────────────────────────────────────────

  describe "visual-line yank and paste" do
    test "Vjy then p pastes two lines below current line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc\nddd")
      BufferProcess.move_to(buffer, {0, 0})
      # V to enter visual-line, j to extend to line 1, y to yank
      send_key(editor, ?V)
      send_key(editor, ?j)
      send_key(editor, ?y)
      # Paste below wherever the cursor is after yank
      send_key(editor, ?p)

      lines = String.split(BufferProcess.content(buffer), "\n")
      # Should have 6 lines: original 4 + 2 pasted
      assert length(lines) == 6
      # The pasted block should contain "aaa" and "bbb" in order
      assert Enum.count(lines, &(&1 == "aaa")) == 2
      assert Enum.count(lines, &(&1 == "bbb")) == 2
    end

    test "Vd then p pastes deleted lines as linewise" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?V)
      send_key(editor, ?j)
      send_key(editor, ?d)
      # "aaa" and "bbb" deleted, cursor on "ccc"
      send_key(editor, ?p)

      assert BufferProcess.content(buffer) == "ccc\naaa\nbbb"
    end
  end

  # ── Visual-char paste (charwise guard) ─────────────────────────────────

  # ── x / X yank into register (#482) ──────────────────────────────────────

  describe "x (delete_char_at) yanks into register" do
    test "x stores deleted char in unnamed register" do
      {editor, buffer} = start_editor("abc")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?x)

      assert BufferProcess.content(buffer) == "bc"
      s = :sys.get_state(editor)
      assert Map.get(s.workspace.editing.reg.registers, "") == {"a", :charwise}
    end

    test "xp transposes two characters" do
      {editor, buffer} = start_editor("ab")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?x)
      send_key(editor, ?p)

      assert BufferProcess.content(buffer) == "ba"
    end

    test "x on empty line is a no-op" do
      {editor, buffer} = start_editor("")
      send_key(editor, ?x)

      assert BufferProcess.content(buffer) == ""
      s = :sys.get_state(editor)
      refute Map.has_key?(s.workspace.editing.reg.registers, "")
    end

    test ~S["ax stores deleted char in named register a] do
      {editor, buffer} = start_editor("abc")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?x)

      assert BufferProcess.content(buffer) == "bc"
      s = :sys.get_state(editor)
      assert Map.get(s.workspace.editing.reg.registers, "a") == {"a", :charwise}
    end

    test ~S["_x deletes without touching any register] do
      {editor, buffer} = start_editor("abc")
      BufferProcess.move_to(buffer, {0, 0})
      # First yank something into unnamed so we can verify it's not overwritten
      send_key(editor, ?y)
      send_key(editor, ?w)
      previous_unnamed = Map.get(:sys.get_state(editor).workspace.editing.reg.registers, "")

      send_key(editor, ?")
      send_key(editor, ?_)
      send_key(editor, ?x)

      assert BufferProcess.content(buffer) == "bc"
      s = :sys.get_state(editor)
      assert Map.get(s.workspace.editing.reg.registers, "") == previous_unnamed
    end

    test "multiple x's each yank the char they delete" do
      {editor, buffer} = start_editor("abcd")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?x)
      send_key(editor, ?x)

      assert BufferProcess.content(buffer) == "cd"
      # Last deleted char ('b') should be in unnamed
      s = :sys.get_state(editor)
      assert Map.get(s.workspace.editing.reg.registers, "") == {"b", :charwise}
    end
  end

  describe "counted x (3x)" do
    test "3x deletes three characters and yanks all three into the register" do
      {editor, buffer} = start_editor("abcdef")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?3)
      send_key(editor, ?x)

      assert BufferProcess.content(buffer) == "def"
      s = :sys.get_state(editor)
      assert Map.get(s.workspace.editing.reg.registers, "") == {"abc", :charwise}
    end

    test "3x then p pastes all three deleted characters" do
      {editor, buffer} = start_editor("abcdef")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?3)
      send_key(editor, ?x)
      send_key(editor, ?$)
      send_key(editor, ?p)

      content = BufferProcess.content(buffer)
      assert String.contains?(content, "abc")
    end

    test "count larger than available chars deletes only what exists" do
      {editor, buffer} = start_editor("ab")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?5)
      send_key(editor, ?x)

      assert BufferProcess.content(buffer) == ""
      s = :sys.get_state(editor)
      assert Map.get(s.workspace.editing.reg.registers, "") == {"ab", :charwise}
    end

    test "3X deletes three characters before cursor and yanks all three" do
      {editor, buffer} = start_editor("abcdef")
      BufferProcess.move_to(buffer, {0, 4})
      send_key(editor, ?3)
      send_key(editor, ?X)

      assert BufferProcess.content(buffer) == "aef"
      s = :sys.get_state(editor)
      # Deleted chars in reading order: "bcd"
      assert Map.get(s.workspace.editing.reg.registers, "") == {"bcd", :charwise}
    end
  end

  describe "X (delete_char_before) yanks into register" do
    test "X stores deleted char in unnamed register" do
      {editor, buffer} = start_editor("abc")
      BufferProcess.move_to(buffer, {0, 1})
      send_key(editor, ?X)

      assert BufferProcess.content(buffer) == "bc"
      s = :sys.get_state(editor)
      assert Map.get(s.workspace.editing.reg.registers, "") == {"a", :charwise}
    end

    test "X at col 0 is a no-op" do
      {editor, buffer} = start_editor("abc")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?X)

      assert BufferProcess.content(buffer) == "abc"
      s = :sys.get_state(editor)
      refute Map.has_key?(s.workspace.editing.reg.registers, "")
    end

    test ~S["aX stores deleted char in named register a] do
      {editor, buffer} = start_editor("abc")
      BufferProcess.move_to(buffer, {0, 2})
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?X)

      assert BufferProcess.content(buffer) == "ac"
      s = :sys.get_state(editor)
      assert Map.get(s.workspace.editing.reg.registers, "a") == {"b", :charwise}
    end
  end

  describe "insert-mode backspace does NOT yank" do
    test "backspace in insert mode deletes without touching registers" do
      {editor, buffer} = start_editor("abc")
      BufferProcess.move_to(buffer, {0, 2})
      # Enter insert mode
      send_key(editor, ?i)
      # Backspace (ASCII DEL)
      send_key(editor, 127)

      assert BufferProcess.content(buffer) == "ac"
      s = :sys.get_state(editor)
      # Register should be empty since insert-mode backspace doesn't yank
      refute Map.has_key?(s.workspace.editing.reg.registers, "")
    end
  end

  describe "s (substitute) yanks deleted char" do
    test "s deletes char, enters insert mode, and yanks deleted char" do
      {editor, buffer} = start_editor("abc")
      BufferProcess.move_to(buffer, {0, 0})
      send_key(editor, ?s)

      assert BufferProcess.content(buffer) == "bc"
      s = :sys.get_state(editor)
      assert s.workspace.editing.mode == :insert
      assert Map.get(s.workspace.editing.reg.registers, "") == {"a", :charwise}
    end
  end

  describe "visual-char yank and paste" do
    test "vllly then p pastes inline" do
      {editor, buffer} = start_editor("abcdefgh")
      BufferProcess.move_to(buffer, {0, 0})
      # select "abcd"
      send_key(editor, ?v)
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?y)
      # move to end and paste
      send_key(editor, ?$)
      send_key(editor, ?p)

      content = BufferProcess.content(buffer)
      refute String.contains?(content, "\n")
    end
  end

  # ── Paste event (mode-independent) ──────────────────────────────────────

  describe "paste event" do
    test "paste inserts text in vim normal mode" do
      {editor, buffer} = start_editor("hello")
      # Don't enter insert mode, stay in normal
      send(editor, {:minga_input, {:paste_event, "world"}})
      _ = :sys.get_state(editor)

      assert String.contains?(BufferProcess.content(buffer), "world")
    end

    test "paste inserts text in vim insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send(editor, {:minga_input, {:paste_event, "xyz"}})
      _ = :sys.get_state(editor)

      assert String.contains?(BufferProcess.content(buffer), "xyz")
    end

    test "paste inserts multiline text" do
      {editor, buffer} = start_editor("start")
      send_key(editor, ?i)
      send(editor, {:minga_input, {:paste_event, "line1\nline2"}})
      _ = :sys.get_state(editor)

      content = BufferProcess.content(buffer)
      assert String.contains?(content, "line1\nline2")
    end
  end

  # ── Autopair without mode gate ──────────────────────────────────────────

  describe "autopair fires regardless of vim mode" do
    test "insert_char autopairs opening bracket in normal mode context" do
      # Autopair should fire for any :insert_char command, because the
      # editing model already decided to produce the command. The executor
      # doesn't second-guess mode.
      {:ok, buffer} = BufferProcess.start_link(content: "")
      BufferProcess.set_option(buffer, :autopair, true)

      state = %MingaEditor.State{
        port_manager: nil,
        workspace: %MingaEditor.Workspace.State{
          viewport: %MingaEditor.Viewport{top: 0, left: 0, rows: 10, cols: 40},
          buffers: %MingaEditor.State.Buffers{active: buffer, list: [buffer]},
          editing: MingaEditor.VimState.new()
        }
      }

      # Execute insert_char directly (bypasses mode FSM, tests the executor)
      MingaEditor.Commands.Editing.execute(state, {:insert_char, "("})

      content = BufferProcess.content(buffer)
      assert content == "()", "autopair should insert closing paren, got: #{inspect(content)}"
    end

    test "delete_before removes autopair in normal mode context" do
      {:ok, buffer} = BufferProcess.start_link(content: "()")
      BufferProcess.set_option(buffer, :autopair, true)
      # Place cursor between the parens (line 0, col 1)
      BufferProcess.move_to(buffer, {0, 1})

      state = %MingaEditor.State{
        port_manager: nil,
        workspace: %MingaEditor.Workspace.State{
          viewport: %MingaEditor.Viewport{top: 0, left: 0, rows: 10, cols: 40},
          buffers: %MingaEditor.State.Buffers{active: buffer, list: [buffer]},
          editing: MingaEditor.VimState.new()
        }
      }

      MingaEditor.Commands.Editing.execute(state, :delete_before)

      content = BufferProcess.content(buffer)
      assert content == "", "autopair should delete both parens, got: #{inspect(content)}"
    end
  end
end
