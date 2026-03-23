defmodule Minga.Editor.Commands.MarksTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  # Three-line buffer: line 0 "hello", line 1 "  world", line 2 "foo"
  @content "hello\n  world\nfoo"

  defp start_editor(content \\ @content) do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_marks_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10
      )

    # Drain init-phase messages (timers, PubSub subscriptions) so they
    # don't interleave with key sequences in the test body.
    _ = :sys.get_state(editor)

    {editor, buffer}
  end

  # Moves the buffer cursor and drains the editor mailbox so no stale
  # messages (events from concurrent tests) interleave with the next key.
  defp move_cursor(editor, buffer, pos) do
    BufferServer.move_to(buffer, pos)
    _ = :sys.get_state(editor)
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  defp state(editor), do: :sys.get_state(editor)

  # ── Setting marks ───────────────────────────────────────────────────────────

  describe "setting marks with m{a-z}" do
    test "m + letter records current cursor position" do
      {editor, buffer} = start_editor()
      # move to line 1, col 0
      move_cursor(editor, buffer, {1, 3})

      send_key(editor, ?m)
      send_key(editor, ?a)

      s = state(editor)
      assert get_in(s.vim.marks, [buffer, "a"]) == {1, 3}
    end

    test "setting the same mark again overwrites the previous position" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {0, 0})
      send_key(editor, ?m)
      send_key(editor, ?z)

      move_cursor(editor, buffer, {2, 2})
      send_key(editor, ?m)
      send_key(editor, ?z)

      s = state(editor)
      assert get_in(s.vim.marks, [buffer, "z"]) == {2, 2}
    end

    test "multiple different marks can coexist" do
      {editor, buffer} = start_editor()

      move_cursor(editor, buffer, {0, 1})
      send_key(editor, ?m)
      send_key(editor, ?a)

      move_cursor(editor, buffer, {2, 0})
      send_key(editor, ?m)
      send_key(editor, ?b)

      s = state(editor)
      assert get_in(s.vim.marks, [buffer, "a"]) == {0, 1}
      assert get_in(s.vim.marks, [buffer, "b"]) == {2, 0}
    end

    test "incomplete m sequence (non-letter) cancels without effect" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {1, 0})

      # Press m then escape — should cancel
      send_key(editor, ?m)
      send_key(editor, 27)

      s = state(editor)
      assert Map.get(s.vim.marks, buffer, %{}) == %{}
    end
  end

  # ── Jumping to marks: single-quote (line) ─────────────────────────────────

  describe "' + {a-z}: jump to first non-blank of marked line" do
    test "jumps to first non-blank column on the marked line" do
      {editor, buffer} = start_editor()
      # Mark line 1 (which is "  world" — first non-blank at col 2)
      move_cursor(editor, buffer, {1, 4})
      send_key(editor, ?m)
      send_key(editor, ?a)

      # Move away then jump back
      move_cursor(editor, buffer, {0, 0})
      send_key(editor, ?')
      send_key(editor, ?a)

      assert BufferServer.cursor(buffer) == {1, 2}
    end

    test "jumping to an unset mark does nothing" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {0, 4})

      send_key(editor, ?')
      send_key(editor, ?z)

      # cursor unchanged
      assert BufferServer.cursor(buffer) == {0, 4}
    end

    test "jumping across lines updates last_jump_pos" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {2, 0})
      send_key(editor, ?m)
      send_key(editor, ?a)

      move_cursor(editor, buffer, {0, 0})
      send_key(editor, ?')
      send_key(editor, ?a)

      s = state(editor)
      assert s.vim.last_jump_pos == {0, 0}
    end

    test "jumping within same line does not update last_jump_pos" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {1, 2})
      send_key(editor, ?m)
      send_key(editor, ?a)

      # Stay on same line but different col
      move_cursor(editor, buffer, {1, 5})
      send_key(editor, ?')
      send_key(editor, ?a)

      s = state(editor)
      assert is_nil(s.vim.last_jump_pos)
    end
  end

  # ── Jumping to marks: backtick (exact) ────────────────────────────────────

  describe "` + {a-z}: jump to exact marked position" do
    test "jumps to the exact line and column of the mark" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {1, 4})
      send_key(editor, ?m)
      send_key(editor, ?b)

      move_cursor(editor, buffer, {0, 0})
      send_key(editor, ?`)
      send_key(editor, ?b)

      assert BufferServer.cursor(buffer) == {1, 4}
    end

    test "jumping to an unset mark does nothing" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {0, 3})

      send_key(editor, ?`)
      send_key(editor, ?x)

      assert BufferServer.cursor(buffer) == {0, 3}
    end

    test "jumping across lines updates last_jump_pos" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {2, 1})
      send_key(editor, ?m)
      send_key(editor, ?c)

      move_cursor(editor, buffer, {0, 2})
      send_key(editor, ?`)
      send_key(editor, ?c)

      s = state(editor)
      assert s.vim.last_jump_pos == {0, 2}
    end
  end

  # ── Jump to last position: '' and `` ──────────────────────────────────────

  describe "'' and `` jump to the position before the last mark jump" do
    test "'' restores to first non-blank of the pre-jump line" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {2, 0})
      send_key(editor, ?m)
      send_key(editor, ?a)

      # From line 0 col 4, jump to mark 'a' on line 2
      move_cursor(editor, buffer, {0, 4})
      send_key(editor, ?')
      send_key(editor, ?a)

      assert BufferServer.cursor(buffer) == {2, 0}

      # Now '' should return to line 0 first non-blank (col 0)
      send_key(editor, ?')
      send_key(editor, ?')

      assert BufferServer.cursor(buffer) == {0, 0}
    end

    test "`` restores to the exact pre-jump position" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {2, 1})
      send_key(editor, ?m)
      send_key(editor, ?d)

      move_cursor(editor, buffer, {0, 3})
      send_key(editor, ?`)
      send_key(editor, ?d)

      assert BufferServer.cursor(buffer) == {2, 1}

      # `` returns to exact position {0, 3}
      send_key(editor, ?`)
      send_key(editor, ?`)

      assert BufferServer.cursor(buffer) == {0, 3}
    end

    test "'' does nothing when no jump has been made yet" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {1, 2})

      send_key(editor, ?')
      send_key(editor, ?')

      # cursor unchanged
      assert BufferServer.cursor(buffer) == {1, 2}
    end

    test "`` does nothing when no jump has been made yet" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {1, 2})

      send_key(editor, ?`)
      send_key(editor, ?`)

      assert BufferServer.cursor(buffer) == {1, 2}
    end

    test "repeated '' toggles back and forth between two positions" do
      {editor, buffer} = start_editor()
      # Set mark 'a' at line 0
      move_cursor(editor, buffer, {0, 0})
      send_key(editor, ?m)
      send_key(editor, ?a)

      # Jump to mark 'a' from line 2; last_jump_pos becomes {2, 0}
      move_cursor(editor, buffer, {2, 0})
      send_key(editor, ?')
      send_key(editor, ?a)
      assert elem(BufferServer.cursor(buffer), 0) == 0

      # First '' → back to pre-jump position (line 2); last_jump_pos becomes {0, 0}
      send_key(editor, ?')
      send_key(editor, ?')
      assert elem(BufferServer.cursor(buffer), 0) == 2

      # Second '' → back to line 0 again
      send_key(editor, ?')
      send_key(editor, ?')
      assert elem(BufferServer.cursor(buffer), 0) == 0
    end
  end

  # ── Marks survive across edits ─────────────────────────────────────────────

  describe "mark persistence" do
    test "marks survive within a buffer session after insertions" do
      {editor, buffer} = start_editor()
      move_cursor(editor, buffer, {1, 0})
      send_key(editor, ?m)
      send_key(editor, ?p)

      # Switch to insert and type something on a different line
      move_cursor(editor, buffer, {0, 0})

      s = state(editor)
      assert get_in(s.vim.marks, [buffer, "p"]) == {1, 0}
    end
  end
end
