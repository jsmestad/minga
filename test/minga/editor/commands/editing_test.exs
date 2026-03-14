defmodule Minga.Editor.Commands.EditingTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  defp start_editor(content) do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10
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

      assert BufferServer.content(buffer) == "xhello"
    end

    test "a moves right and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?a)
      send_key(editor, ?x)

      assert String.contains?(BufferServer.content(buffer), "x")
    end

    test "A moves to line end and enters insert mode" do
      {editor, buffer} = start_editor("hi")
      send_key(editor, ?A)
      send_key(editor, ?!)

      assert String.contains?(BufferServer.content(buffer), "!")
    end

    test "I moves to line start and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?I)
      send_key(editor, ?^)

      assert String.starts_with?(BufferServer.content(buffer), "^")
    end

    test "o inserts a new line below and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?o)
      send_key(editor, ?w)

      content = BufferServer.content(buffer)
      assert String.contains?(content, "\n")
      assert String.contains?(content, "w")
    end

    test "O inserts a new line above and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?O)
      send_key(editor, ?w)

      content = BufferServer.content(buffer)
      assert String.contains?(content, "\n")
      assert String.contains?(content, "w")
    end
  end

  describe "Insert mode operations" do
    test "insert character updates buffer" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?i)
      send_key(editor, ?x)

      assert BufferServer.content(buffer) == "xhello\nworld\nfoo"
    end

    test "backspace (127) deletes character in insert mode" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?i)
      send_key(editor, ?a)
      _ = :sys.get_state(editor)
      send_key(editor, 127)

      assert BufferServer.content(buffer) == "hello\nworld\nfoo"
    end

    test "enter inserts newline in insert mode" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?i)
      send_key(editor, 13)

      assert BufferServer.content(buffer) == "\nhello\nworld\nfoo"
    end
  end

  describe "Insert → Normal transition" do
    test "Escape returns to Normal mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)
      send_key(editor, 27)

      content_before = BufferServer.content(buffer)
      send_key(editor, ?l)
      assert BufferServer.content(buffer) == content_before
    end
  end

  describe "undo / redo" do
    test "u undoes the last change" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)
      send_key(editor, 27)

      assert BufferServer.content(buffer) == "xhello"
      send_key(editor, ?u)
      assert BufferServer.content(buffer) == "hello"
    end

    test "Ctrl+r redoes after undo" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)
      send_key(editor, 27)

      send_key(editor, ?u)
      assert BufferServer.content(buffer) == "hello"

      send_key(editor, ?r, 0x02)
      assert BufferServer.content(buffer) == "xhello"
    end
  end

  describe "paste operations" do
    test "p pastes after cursor" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      content = BufferServer.content(buffer)
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

      assert String.contains?(BufferServer.content(buffer), "hello")
    end

    test "p is a no-op when register is empty" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)
      send_key(editor, ?p)
      assert BufferServer.content(buffer) == original
    end

    test "P is a no-op when register is empty" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)
      send_key(editor, ?P)
      assert BufferServer.content(buffer) == original
    end
  end

  # ── Linewise paste ──────────────────────────────────────────────────────

  describe "linewise paste (yy + p)" do
    test "yy then p pastes yanked line below the current line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      assert BufferServer.content(buffer) == "aaa\nbbb\naaa\nccc"
    end

    test "yy then P pastes yanked line above the current line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      # move to line 2, paste above
      send_key(editor, ?j)
      send_key(editor, ?j)
      send_key(editor, ?P)

      assert BufferServer.content(buffer) == "aaa\nbbb\naaa\nccc"
    end

    test "p on the last line of the file appends a new line" do
      {editor, buffer} = start_editor("aaa\nbbb")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      assert BufferServer.content(buffer) == "aaa\nbbb\naaa"
    end

    test "P on the first line of the file inserts above" do
      {editor, buffer} = start_editor("aaa\nbbb")
      BufferServer.move_to(buffer, {1, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?P)

      assert BufferServer.content(buffer) == "bbb\naaa\nbbb"
    end

    test "cursor column is irrelevant for linewise paste" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      # move to middle of line 1
      BufferServer.move_to(buffer, {1, 2})
      send_key(editor, ?p)

      # Should still paste as a full new line, not splice at col 2
      assert BufferServer.content(buffer) == "aaa\nbbb\naaa\nccc"
    end
  end

  describe "linewise paste (dd + p/P)" do
    test "dd then p moves deleted line below current line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?d)
      send_key(editor, ?d)
      send_key(editor, ?p)

      assert BufferServer.content(buffer) == "bbb\naaa\nccc"
    end

    test "dd then P pastes deleted line above current line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferServer.move_to(buffer, {1, 0})
      send_key(editor, ?d)
      send_key(editor, ?d)
      # cursor is now on "ccc"
      send_key(editor, ?P)

      assert BufferServer.content(buffer) == "aaa\nbbb\nccc"
    end
  end

  describe "linewise paste cursor positioning" do
    test "p lands cursor on first non-blank of pasted line" do
      {editor, buffer} = start_editor("  indented\nplain")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      {line, col} = BufferServer.cursor(buffer)
      assert line == 2
      assert col == 2
    end

    test "P lands cursor on first non-blank of pasted line" do
      {editor, buffer} = start_editor("plain\n    deep")
      BufferServer.move_to(buffer, {1, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?P)

      {line, col} = BufferServer.cursor(buffer)
      assert line == 0
      assert col == 4
    end

    test "p with no-indent line lands cursor at col 0" do
      {editor, buffer} = start_editor("noindent\nother")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      {line, col} = BufferServer.cursor(buffer)
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
      assert Map.get(s.vim.reg.registers, "") == {"hello\n", :linewise}
    end
  end

  # ── Charwise paste (regression guard) ──────────────────────────────────

  describe "charwise paste stays inline" do
    test "yw then p pastes inline, no new line created" do
      {editor, buffer} = start_editor("hello world")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?w)
      send_key(editor, ?$)
      send_key(editor, ?p)

      content = BufferServer.content(buffer)
      refute String.contains?(content, "\n")
    end

    # NOTE: Vim's `x` should yank the deleted char into the unnamed register,
    # but our `delete_at` doesn't do that yet. This test documents current
    # behavior. When `x` is fixed to yank, update this test to assert "bac".
    test "x does not currently store to register (known gap)" do
      {editor, buffer} = start_editor("abc")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?x)
      assert BufferServer.content(buffer) == "bc"

      # p is a no-op because x didn't yank
      send_key(editor, ?p)
      assert BufferServer.content(buffer) == "bc"
    end

    test "dw then p pastes deleted word inline" do
      {editor, buffer} = start_editor("one two three")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?d)
      send_key(editor, ?w)
      # "one " deleted, cursor at "two"
      send_key(editor, ?$)
      send_key(editor, ?p)

      content = BufferServer.content(buffer)
      refute String.contains?(content, "\n")
      assert String.contains?(content, "one ")
    end
  end

  # ── Named register linewise round-trip ─────────────────────────────────

  describe "named register linewise round-trip" do
    test ~S["ayy then "ap pastes as a new line] do
      {editor, buffer} = start_editor("first\nsecond\nthird")
      BufferServer.move_to(buffer, {0, 0})
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

      assert BufferServer.content(buffer) == "first\nsecond\nthird\nfirst"
    end

    test "named register preserves linewise type through multiple operations" do
      {editor, buffer} = start_editor("alpha\nbeta\ngamma")
      BufferServer.move_to(buffer, {0, 0})
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

      assert BufferServer.content(buffer) == "alpha\ngamma\nalpha"
    end
  end

  # ── Visual-line paste ──────────────────────────────────────────────────

  describe "visual-line yank and paste" do
    test "Vjy then p pastes two lines below current line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc\nddd")
      BufferServer.move_to(buffer, {0, 0})
      # V to enter visual-line, j to extend to line 1, y to yank
      send_key(editor, ?V)
      send_key(editor, ?j)
      send_key(editor, ?y)
      # Paste below wherever the cursor is after yank
      send_key(editor, ?p)

      lines = String.split(BufferServer.content(buffer), "\n")
      # Should have 6 lines: original 4 + 2 pasted
      assert length(lines) == 6
      # The pasted block should contain "aaa" and "bbb" in order
      assert Enum.count(lines, &(&1 == "aaa")) == 2
      assert Enum.count(lines, &(&1 == "bbb")) == 2
    end

    test "Vd then p pastes deleted lines as linewise" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?V)
      send_key(editor, ?j)
      send_key(editor, ?d)
      # "aaa" and "bbb" deleted, cursor on "ccc"
      send_key(editor, ?p)

      assert BufferServer.content(buffer) == "ccc\naaa\nbbb"
    end
  end

  # ── Visual-char paste (charwise guard) ─────────────────────────────────

  describe "visual-char yank and paste" do
    test "vllly then p pastes inline" do
      {editor, buffer} = start_editor("abcdefgh")
      BufferServer.move_to(buffer, {0, 0})
      # select "abcd"
      send_key(editor, ?v)
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?y)
      # move to end and paste
      send_key(editor, ?$)
      send_key(editor, ?p)

      content = BufferServer.content(buffer)
      refute String.contains?(content, "\n")
    end
  end
end
