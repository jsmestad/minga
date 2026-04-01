defmodule MingaEditor.Commands.OperatorsTest do
  @moduledoc """
  Tests for counted line operators (delete_lines_counted, change_lines_counted,
  yank_lines_counted) in MingaEditor.Commands.Operators.

  Calls `Operators.execute/2` directly on constructed EditorState structs
  with a real BufferServer. No Editor GenServer needed.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor.Commands.Operators
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Registers
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp start_buffer(content) do
    start_supervised!({BufferServer, content: content})
  end

  defp build_state(buf) do
    %EditorState{
      port_manager: nil,
      workspace: %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %MingaEditor.State.Buffers{active: buf, list: [buf]}
      }
    }
  end

  defp register_entry(state, name \\ "") do
    Registers.get(state.workspace.editing.reg, name)
  end

  # ── delete_lines_counted ───────────────────────────────────────────────

  describe "delete_lines_counted" do
    test "1 (dd) deletes the current line" do
      buf = start_buffer("hello\nworld\nfoo")
      state = build_state(buf)

      new_state = Operators.execute(state, {:delete_lines_counted, 1})

      assert BufferServer.content(buf) == "world\nfoo"
      assert register_entry(new_state) == {"hello\n", :linewise}
    end

    test "2dd deletes two lines from cursor" do
      buf = start_buffer("aaa\nbbb\nccc\nddd")
      state = build_state(buf)

      new_state = Operators.execute(state, {:delete_lines_counted, 2})

      assert BufferServer.content(buf) == "ccc\nddd"
      assert register_entry(new_state) == {"aaa\nbbb\n", :linewise}
    end

    test "3dd deletes three lines from cursor" do
      buf = start_buffer("line1\nline2\nline3\nline4\nline5")
      state = build_state(buf)

      new_state = Operators.execute(state, {:delete_lines_counted, 3})

      assert BufferServer.content(buf) == "line4\nline5"
      assert register_entry(new_state) == {"line1\nline2\nline3\n", :linewise}
    end

    test "2dd from middle line deletes that line and next" do
      buf = start_buffer("aaa\nbbb\nccc\nddd")
      BufferServer.move_to(buf, {1, 0})
      state = build_state(buf)

      new_state = Operators.execute(state, {:delete_lines_counted, 2})

      assert BufferServer.content(buf) == "aaa\nddd"
      assert register_entry(new_state) == {"bbb\nccc\n", :linewise}
    end

    test "count exceeding buffer clamps to last line" do
      buf = start_buffer("aaa\nbbb")
      state = build_state(buf)

      new_state = Operators.execute(state, {:delete_lines_counted, 5})

      assert BufferServer.content(buf) == ""
      assert register_entry(new_state) == {"aaa\nbbb\n", :linewise}
    end

    test "dd on single line clears buffer" do
      buf = start_buffer("only line")
      state = build_state(buf)

      new_state = Operators.execute(state, {:delete_lines_counted, 1})

      assert BufferServer.content(buf) == ""
      assert register_entry(new_state) == {"only line\n", :linewise}
    end

    test "deleted text goes to unnamed register, not yank register 0" do
      buf = start_buffer("aaa\nbbb\nccc")
      state = build_state(buf)

      new_state = Operators.execute(state, {:delete_lines_counted, 2})

      assert register_entry(new_state, "") == {"aaa\nbbb\n", :linewise}
      assert register_entry(new_state, "0") == nil
    end

    test "cursor on last line with count > 1 deletes only that line" do
      buf = start_buffer("aaa\nbbb\nccc")
      BufferServer.move_to(buf, {2, 0})
      state = build_state(buf)

      new_state = Operators.execute(state, {:delete_lines_counted, 3})

      assert BufferServer.content(buf) == "aaa\nbbb"
      assert register_entry(new_state) == {"ccc\n", :linewise}
    end
  end

  # ── change_lines_counted ───────────────────────────────────────────────

  describe "change_lines_counted" do
    test "cc clears current line" do
      buf = start_buffer("hello\nworld\nfoo")
      state = build_state(buf)

      new_state = Operators.execute(state, {:change_lines_counted, 1})

      content = BufferServer.content(buf)
      refute String.contains?(content, "hello")
      assert String.contains?(content, "world")
      assert register_entry(new_state) == {"hello\n", :linewise}
    end

    test "2cc deletes both lines, register has both" do
      buf = start_buffer("aaa\nbbb\nccc\nddd")
      state = build_state(buf)

      new_state = Operators.execute(state, {:change_lines_counted, 2})

      content = BufferServer.content(buf)
      refute String.contains?(content, "aaa")
      refute String.contains?(content, "bbb")
      assert String.contains?(content, "ccc")
      assert register_entry(new_state) == {"aaa\nbbb\n", :linewise}
    end
  end

  # ── yank_lines_counted ────────────────────────────────────────────────

  describe "yank_lines_counted" do
    test "yy yanks current line without modifying buffer" do
      buf = start_buffer("hello\nworld")
      state = build_state(buf)

      new_state = Operators.execute(state, {:yank_lines_counted, 1})

      assert BufferServer.content(buf) == "hello\nworld"
      assert register_entry(new_state) == {"hello\n", :linewise}
    end

    test "2yy yanks two lines without modifying buffer" do
      buf = start_buffer("aaa\nbbb\nccc")
      state = build_state(buf)

      new_state = Operators.execute(state, {:yank_lines_counted, 2})

      assert BufferServer.content(buf) == "aaa\nbbb\nccc"
      assert register_entry(new_state) == {"aaa\nbbb\n", :linewise}
    end

    test "yank stores in both unnamed and yank register 0" do
      buf = start_buffer("aaa\nbbb\nccc")
      state = build_state(buf)

      new_state = Operators.execute(state, {:yank_lines_counted, 2})

      assert register_entry(new_state, "") == {"aaa\nbbb\n", :linewise}
      assert register_entry(new_state, "0") == {"aaa\nbbb\n", :linewise}
    end

    test "yank count exceeding buffer clamps to last line" do
      buf = start_buffer("aaa\nbbb")
      state = build_state(buf)

      new_state = Operators.execute(state, {:yank_lines_counted, 5})

      assert BufferServer.content(buf) == "aaa\nbbb"
      assert register_entry(new_state) == {"aaa\nbbb\n", :linewise}
    end
  end
end
