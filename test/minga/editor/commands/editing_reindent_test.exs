defmodule Minga.Editor.Commands.EditingReindentTest do
  @moduledoc """
  Tests for the = operator (reindent) mode transitions and dispatch.

  Verifies that ==, =<motion>, and visual = correctly route through
  operator-pending mode and return to normal mode. Content-level indent
  correctness is tested in `test/minga/editor/indent_test.exs`.
  """
  use Minga.Test.EditingModelCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  defp start_editor(content) do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"reindent_editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 80,
        height: 24
      )

    {editor, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  # ── == mode transitions ────────────────────────────────────────────────────

  describe "== mode transitions" do
    test "first = enters operator-pending with :reindent" do
      {editor, _buffer} = start_editor("line 1\nline 2")
      send_key(editor, ?=)

      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :operator_pending
      assert state.workspace.editing.mode_state.operator == :reindent
    end

    test "== returns to normal mode" do
      {editor, _buffer} = start_editor("line 1\nline 2")
      send_key(editor, ?=)
      send_key(editor, ?=)

      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :normal
    end

    test "=w returns to normal mode (word motion)" do
      {editor, _buffer} = start_editor("line 1\nline 2\nline 3")
      send_key(editor, ?=)
      send_key(editor, ?w)

      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :normal
    end

    test "=G returns to normal mode" do
      {editor, _buffer} = start_editor("line 1\nline 2\nline 3")
      send_key(editor, ?=)
      send_key(editor, ?G)

      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :normal
    end

    test "=gg returns to normal mode" do
      {editor, _buffer} = start_editor("line 1\nline 2\nline 3")
      send_key(editor, ?j)
      send_key(editor, ?=)
      send_key(editor, ?g)
      send_key(editor, ?g)

      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :normal
    end
  end

  # ── Visual = mode transitions ──────────────────────────────────────────────

  describe "visual = mode transitions" do
    test "V j = reindents visual selection and returns to normal" do
      {editor, _buffer} = start_editor("line 1\nline 2\nline 3")
      send_key(editor, ?V)
      send_key(editor, ?j)
      send_key(editor, ?=)

      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :normal
    end

    test "v l = returns to normal after characterwise reindent" do
      {editor, _buffer} = start_editor("line 1\nline 2")
      send_key(editor, ?v)
      send_key(editor, ?j)
      send_key(editor, ?=)

      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :normal
    end
  end

  # ── = with text objects ────────────────────────────────────────────────────

  describe "= with text objects" do
    test "=iw enters operator-pending then dispatches and returns to normal" do
      {editor, _buffer} = start_editor("hello world")
      send_key(editor, ?=)

      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :operator_pending

      send_key(editor, ?i)
      send_key(editor, ?w)

      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :normal
    end
  end

  # ── Content verification (simple cases) ────────────────────────────────────

  describe "content verification" do
    test "== does not corrupt buffer content" do
      content = "hello\nworld\nfoo"
      {editor, buffer} = start_editor(content)
      send_key(editor, ?=)
      send_key(editor, ?=)

      result = BufferServer.content(buffer)
      # Content should not lose characters. The line may gain/lose whitespace
      # but the non-whitespace content should be preserved.
      assert String.contains?(result, "hello")
    end

    test "=G does not crash on multi-line buffer" do
      {editor, buffer} = start_editor("a\nb\nc\nd\ne")
      send_key(editor, ?=)
      send_key(editor, ?G)

      result = BufferServer.content(buffer)
      assert is_binary(result)
      # All original non-whitespace content should be preserved
      for char <- ["a", "b", "c", "d", "e"] do
        assert String.contains?(result, char),
               "Expected '#{char}' to be preserved after =G, content: #{inspect(result)}"
      end
    end
  end
end
