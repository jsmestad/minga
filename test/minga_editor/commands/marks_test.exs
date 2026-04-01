defmodule MingaEditor.Commands.MarksTest do
  @moduledoc """
  Tests for mark commands (set, jump-to-line, jump-to-exact, jump-to-last).

  Calls `Marks.execute/2` directly on constructed EditorState structs with
  a real BufferServer for cursor operations. No Editor GenServer needed.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor.Commands.Marks
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  # "hello\n  world\nfoo" — line 1 has leading spaces (first non-blank at col 2)
  @content "hello\n  world\nfoo"

  defp start_buffer(content \\ @content) do
    start_supervised!({BufferServer, content: content})
  end

  defp make_state(buffer, opts \\ []) do
    marks = Keyword.get(opts, :marks, %{})
    last_jump_pos = Keyword.get(opts, :last_jump_pos, nil)

    vim = %VimState{
      mode: :normal,
      mode_state: Minga.Mode.initial_state(),
      marks: marks,
      last_jump_pos: last_jump_pos
    }

    %EditorState{
      port_manager: nil,
      workspace: %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %MingaEditor.State.Buffers{active: buffer},
        editing: vim
      }
    }
  end

  defp get_mark(state, buffer, char) do
    get_in(state.workspace.editing.marks, [buffer, char])
  end

  # ── set_mark ────────────────────────────────────────────────────────────

  describe "set_mark" do
    test "records current cursor position keyed by buffer and char" do
      buf = start_buffer()
      BufferServer.move_to(buf, {1, 3})
      state = make_state(buf)

      new_state = Marks.execute(state, {:set_mark, "a"})

      assert get_mark(new_state, buf, "a") == {1, 3}
    end

    test "overwrites existing mark for same char" do
      buf = start_buffer()
      BufferServer.move_to(buf, {0, 0})
      state = make_state(buf, marks: %{buf => %{"a" => {0, 0}}})

      BufferServer.move_to(buf, {2, 1})
      new_state = Marks.execute(state, {:set_mark, "a"})

      assert get_mark(new_state, buf, "a") == {2, 1}
    end

    test "preserves other marks when setting a new one" do
      buf = start_buffer()
      BufferServer.move_to(buf, {0, 1})
      state = make_state(buf, marks: %{buf => %{"a" => {0, 1}}})

      BufferServer.move_to(buf, {2, 0})
      new_state = Marks.execute(state, {:set_mark, "b"})

      assert get_mark(new_state, buf, "a") == {0, 1}
      assert get_mark(new_state, buf, "b") == {2, 0}
    end

    test "multiple different marks can coexist" do
      buf = start_buffer()

      BufferServer.move_to(buf, {0, 1})
      state = Marks.execute(make_state(buf), {:set_mark, "a"})

      BufferServer.move_to(buf, {2, 0})
      state = Marks.execute(state, {:set_mark, "b"})

      assert get_mark(state, buf, "a") == {0, 1}
      assert get_mark(state, buf, "b") == {2, 0}
    end
  end

  # ── jump_to_mark_line ──────────────────────────────────────────────────

  describe "jump_to_mark_line" do
    test "jumps to first non-blank column on the marked line" do
      buf = start_buffer()
      # Mark line 1 at col 4 ("  world", first non-blank at col 2)
      state = make_state(buf, marks: %{buf => %{"a" => {1, 4}}})
      BufferServer.move_to(buf, {0, 0})

      _new = Marks.execute(state, {:jump_to_mark_line, "a"})

      assert BufferServer.cursor(buf) == {1, 2}
    end

    test "unset mark is a no-op" do
      buf = start_buffer()
      BufferServer.move_to(buf, {0, 4})
      state = make_state(buf)

      _new = Marks.execute(state, {:jump_to_mark_line, "z"})

      assert BufferServer.cursor(buf) == {0, 4}
    end

    test "cross-line jump saves last_jump_pos" do
      buf = start_buffer()
      BufferServer.move_to(buf, {0, 0})
      state = make_state(buf, marks: %{buf => %{"a" => {2, 0}}})

      new_state = Marks.execute(state, {:jump_to_mark_line, "a"})

      assert new_state.workspace.editing.last_jump_pos == {0, 0}
    end

    test "same-line jump does not save last_jump_pos" do
      buf = start_buffer()
      BufferServer.move_to(buf, {1, 5})
      state = make_state(buf, marks: %{buf => %{"a" => {1, 2}}})

      new_state = Marks.execute(state, {:jump_to_mark_line, "a"})

      assert is_nil(new_state.workspace.editing.last_jump_pos)
    end

    test "jumping to mark on empty line lands at col 0" do
      buf = start_buffer("hello\n\nfoo")
      BufferServer.move_to(buf, {0, 0})
      state = make_state(buf, marks: %{buf => %{"a" => {1, 0}}})

      _new = Marks.execute(state, {:jump_to_mark_line, "a"})

      assert BufferServer.cursor(buf) == {1, 0}
    end
  end

  # ── jump_to_mark_exact ─────────────────────────────────────────────────

  describe "jump_to_mark_exact" do
    test "jumps to the exact line and column of the mark" do
      buf = start_buffer()
      BufferServer.move_to(buf, {0, 0})
      state = make_state(buf, marks: %{buf => %{"b" => {1, 4}}})

      _new = Marks.execute(state, {:jump_to_mark_exact, "b"})

      assert BufferServer.cursor(buf) == {1, 4}
    end

    test "unset mark is a no-op" do
      buf = start_buffer()
      BufferServer.move_to(buf, {0, 3})
      state = make_state(buf)

      _new = Marks.execute(state, {:jump_to_mark_exact, "x"})

      assert BufferServer.cursor(buf) == {0, 3}
    end

    test "cross-line jump saves last_jump_pos" do
      buf = start_buffer()
      BufferServer.move_to(buf, {0, 2})
      state = make_state(buf, marks: %{buf => %{"c" => {2, 1}}})

      new_state = Marks.execute(state, {:jump_to_mark_exact, "c"})

      assert new_state.workspace.editing.last_jump_pos == {0, 2}
    end
  end

  # ── jump_to_last_pos_line ──────────────────────────────────────────────

  describe "jump_to_last_pos_line" do
    test "jumps to first non-blank of the saved line" do
      buf = start_buffer()
      # last_jump_pos on line 1 ("  world", first non-blank at col 2)
      BufferServer.move_to(buf, {2, 0})
      state = make_state(buf, last_jump_pos: {1, 4})

      _new = Marks.execute(state, :jump_to_last_pos_line)

      assert BufferServer.cursor(buf) == {1, 2}
    end

    test "updates last_jump_pos to pre-jump position" do
      buf = start_buffer()
      BufferServer.move_to(buf, {2, 0})
      state = make_state(buf, last_jump_pos: {0, 3})

      new_state = Marks.execute(state, :jump_to_last_pos_line)

      assert new_state.workspace.editing.last_jump_pos == {2, 0}
    end

    test "nil last_jump_pos is a no-op" do
      buf = start_buffer()
      BufferServer.move_to(buf, {1, 2})
      state = make_state(buf)

      new_state = Marks.execute(state, :jump_to_last_pos_line)

      assert BufferServer.cursor(buf) == {1, 2}
      assert is_nil(new_state.workspace.editing.last_jump_pos)
    end

    test "repeated calls toggle between two positions" do
      buf = start_buffer()
      BufferServer.move_to(buf, {2, 0})
      state = make_state(buf, last_jump_pos: {0, 3})

      # First call: jump to line 0, save {2, 0}
      state = Marks.execute(state, :jump_to_last_pos_line)
      assert elem(BufferServer.cursor(buf), 0) == 0
      assert state.workspace.editing.last_jump_pos == {2, 0}

      # Second call: jump to line 2, save {0, 0}
      _state = Marks.execute(state, :jump_to_last_pos_line)
      assert elem(BufferServer.cursor(buf), 0) == 2
    end
  end

  # ── jump_to_last_pos_exact ─────────────────────────────────────────────

  describe "jump_to_last_pos_exact" do
    test "jumps to the exact saved position" do
      buf = start_buffer()
      BufferServer.move_to(buf, {2, 1})
      state = make_state(buf, last_jump_pos: {0, 3})

      _new = Marks.execute(state, :jump_to_last_pos_exact)

      assert BufferServer.cursor(buf) == {0, 3}
    end

    test "updates last_jump_pos to pre-jump position" do
      buf = start_buffer()
      BufferServer.move_to(buf, {2, 1})
      state = make_state(buf, last_jump_pos: {0, 3})

      new_state = Marks.execute(state, :jump_to_last_pos_exact)

      assert new_state.workspace.editing.last_jump_pos == {2, 1}
    end

    test "nil last_jump_pos is a no-op" do
      buf = start_buffer()
      BufferServer.move_to(buf, {1, 2})
      state = make_state(buf)

      new_state = Marks.execute(state, :jump_to_last_pos_exact)

      assert BufferServer.cursor(buf) == {1, 2}
      assert is_nil(new_state.workspace.editing.last_jump_pos)
    end

    test "repeated calls toggle between two exact positions" do
      buf = start_buffer()
      BufferServer.move_to(buf, {0, 3})
      state = make_state(buf, last_jump_pos: {2, 1})

      state = Marks.execute(state, :jump_to_last_pos_exact)
      assert BufferServer.cursor(buf) == {2, 1}
      assert state.workspace.editing.last_jump_pos == {0, 3}

      state = Marks.execute(state, :jump_to_last_pos_exact)
      assert BufferServer.cursor(buf) == {0, 3}
      assert state.workspace.editing.last_jump_pos == {2, 1}
    end
  end
end
