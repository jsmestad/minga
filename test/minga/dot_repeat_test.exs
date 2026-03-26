defmodule Minga.DotRepeatTest do
  @moduledoc """
  Integration tests for dot repeat (`.`) — GitHub issue #49.

  Tests the full flow through the Editor GenServer: key events →
  Mode FSM → ChangeRecorder → replay.
  """
  use Minga.Test.EditingModelCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  @escape 27

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp start_editor(content) do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
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

  defp type_string(editor, text) do
    text
    |> String.to_charlist()
    |> Enum.each(fn char -> send_key(editor, char) end)
  end

  defp content(buffer) do
    BufferServer.content(buffer)
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "single-key edit repeat" do
    test "x then . deletes two characters" do
      {editor, buffer} = start_editor("abcdef")
      # x deletes 'a'
      send_key(editor, ?x)
      assert content(buffer) == "bcdef"

      # . repeats x, deletes 'b'
      send_key(editor, ?.)
      assert content(buffer) == "cdef"
    end

    test "~ then . toggles case of two characters" do
      {editor, buffer} = start_editor("abc")
      send_key(editor, ?~)
      assert content(buffer) == "Abc"

      send_key(editor, ?.)
      assert content(buffer) == "ABc"
    end
  end

  describe "insert mode repeat" do
    test "i + type text + Escape, then . inserts text again" do
      {editor, buffer} = start_editor("")

      # Enter insert mode, type "hi", escape
      send_key(editor, ?i)
      type_string(editor, "hi")
      send_key(editor, @escape)
      assert content(buffer) == "hi"

      # . replays: enter insert at current cursor, type "hi", escape
      # Cursor is at end of "hi" (no move-left on Escape in this editor)
      send_key(editor, ?.)
      assert content(buffer) == "hihi"
    end

    test "o + type text + Escape, then . opens line and types again" do
      {editor, buffer} = start_editor("line1")

      send_key(editor, ?o)
      type_string(editor, "new")
      send_key(editor, @escape)
      assert content(buffer) == "line1\nnew"

      send_key(editor, ?.)
      assert content(buffer) == "line1\nnew\nnew"
    end
  end

  describe "operator + motion repeat" do
    test "dd then . deletes another line" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")

      send_key(editor, ?d)
      send_key(editor, ?d)
      assert content(buffer) == "bbb\nccc"

      send_key(editor, ?.)
      assert content(buffer) == "ccc"
    end

    test "delete_line then . works repeatedly" do
      {editor, buffer} = start_editor("1\n2\n3\n4")

      send_key(editor, ?d)
      send_key(editor, ?d)
      assert content(buffer) == "2\n3\n4"

      send_key(editor, ?.)
      assert content(buffer) == "3\n4"

      send_key(editor, ?.)
      assert content(buffer) == "4"
    end
  end

  describe "replace char repeat" do
    test "r<char> then . replaces next char with same character" do
      {editor, buffer} = start_editor("abc")

      send_key(editor, ?r)
      send_key(editor, ?Z)
      assert content(buffer) == "Zbc"

      # Move right and repeat
      send_key(editor, ?l)
      send_key(editor, ?.)
      assert content(buffer) == "ZZc"
    end
  end

  describe "indent/dedent repeat" do
    test ">> then . indents twice" do
      {editor, buffer} = start_editor("hello")

      send_key(editor, ?>)
      send_key(editor, ?>)
      assert content(buffer) == "  hello"

      send_key(editor, ?.)
      assert content(buffer) == "    hello"
    end
  end

  describe "dot repeat with no prior change" do
    test ". with no prior change is a no-op" do
      {editor, buffer} = start_editor("hello")

      send_key(editor, ?.)
      assert content(buffer) == "hello"
      assert BufferServer.cursor(buffer) == {0, 0}
    end
  end

  describe "count with dot repeat" do
    test "x then 3. deletes three characters" do
      {editor, buffer} = start_editor("abcdef")
      send_key(editor, ?x)
      assert content(buffer) == "bcdef"

      # 3. should delete 3 chars
      send_key(editor, ?3)
      send_key(editor, ?.)
      assert content(buffer) == "ef"
    end
  end

  describe "motions do not overwrite last change" do
    test "motion after edit does not break dot repeat" do
      {editor, buffer} = start_editor("abcdef")

      # x deletes 'a'
      send_key(editor, ?x)
      assert content(buffer) == "bcdef"

      # Move right (motion — should not affect recording)
      send_key(editor, ?l)
      send_key(editor, ?l)

      # . should still repeat x
      send_key(editor, ?.)
      assert content(buffer) == "bcef"
    end
  end
end
