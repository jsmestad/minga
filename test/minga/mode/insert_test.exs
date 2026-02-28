defmodule Minga.Mode.InsertTest do
  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Mode.Insert

  defp fresh_state, do: Mode.initial_state()

  describe "Escape key" do
    test "Escape transitions to :normal" do
      assert {:transition, :normal, _} = Insert.handle_key({27, 0}, fresh_state())
    end

    test "Escape with any modifier still transitions to :normal" do
      assert {:transition, :normal, _} = Insert.handle_key({27, 4}, fresh_state())
    end
  end

  describe "Backspace / Delete" do
    test "DEL (127) emits :delete_before" do
      assert {:execute, :delete_before, _} = Insert.handle_key({127, 0}, fresh_state())
    end

    test "BS (8) emits :delete_before" do
      assert {:execute, :delete_before, _} = Insert.handle_key({8, 0}, fresh_state())
    end
  end

  describe "Enter key" do
    test "Enter (13) emits :insert_newline" do
      assert {:execute, :insert_newline, _} = Insert.handle_key({13, 0}, fresh_state())
    end
  end

  describe "printable characters" do
    test "ASCII letter 'x' emits {:insert_char, \"x\"}" do
      assert {:execute, {:insert_char, "x"}, _} = Insert.handle_key({?x, 0}, fresh_state())
    end

    test "ASCII letter 'A' emits {:insert_char, \"A\"}" do
      assert {:execute, {:insert_char, "A"}, _} = Insert.handle_key({?A, 0}, fresh_state())
    end

    test "space (32) emits {:insert_char, \" \"}" do
      assert {:execute, {:insert_char, " "}, _} = Insert.handle_key({32, 0}, fresh_state())
    end

    test "Unicode codepoint 169 (©) emits {:insert_char, \"©\"}" do
      assert {:execute, {:insert_char, "©"}, _} = Insert.handle_key({169, 0}, fresh_state())
    end

    test "emoji codepoint U+1F600 emits insert_char with the emoji glyph" do
      # 😀 = U+1F600
      assert {:execute, {:insert_char, "😀"}, _} =
               Insert.handle_key({0x1F600, 0}, fresh_state())
    end
  end

  describe "arrow keys" do
    test "up arrow (57416) emits :move_up" do
      assert {:execute, :move_up, _} = Insert.handle_key({57416, 0}, fresh_state())
    end

    test "down arrow (57424) emits :move_down" do
      assert {:execute, :move_down, _} = Insert.handle_key({57424, 0}, fresh_state())
    end

    test "left arrow (57419) emits :move_left" do
      assert {:execute, :move_left, _} = Insert.handle_key({57419, 0}, fresh_state())
    end

    test "right arrow (57421) emits :move_right" do
      assert {:execute, :move_right, _} = Insert.handle_key({57421, 0}, fresh_state())
    end
  end

  describe "ignored keys" do
    test "control character (Ctrl+C) is ignored" do
      assert {:continue, _} = Insert.handle_key({?c, 2}, fresh_state())
    end

    test "unknown high codepoint with modifier is ignored" do
      assert {:continue, _} = Insert.handle_key({?x, 4}, fresh_state())
    end
  end

  describe "state passthrough" do
    test "insert mode does not modify the FSM state" do
      state = %{count: nil, extra: :data}
      {:execute, {:insert_char, "a"}, returned_state} = Insert.handle_key({?a, 0}, state)
      assert returned_state == state
    end
  end
end
