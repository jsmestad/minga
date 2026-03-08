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
    test "up arrow (57_352) emits :move_up" do
      assert {:execute, :move_up, _} = Insert.handle_key({57_352, 0}, fresh_state())
    end

    test "down arrow (57_353) emits :move_down" do
      assert {:execute, :move_down, _} = Insert.handle_key({57_353, 0}, fresh_state())
    end

    test "left arrow (57_350) emits :move_left" do
      assert {:execute, :move_left, _} = Insert.handle_key({57_350, 0}, fresh_state())
    end

    test "right arrow (57_351) emits :move_right" do
      assert {:execute, :move_right, _} = Insert.handle_key({57_351, 0}, fresh_state())
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

defmodule Minga.Mode.Insert.UserOverrideTest do
  @moduledoc "Tests for user-defined insert mode bindings via Keymap.Active."
  use ExUnit.Case, async: false

  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Mode
  alias Minga.Mode.Insert

  defp fresh_state, do: Mode.initial_state()

  setup do
    case KeymapActive.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> KeymapActive.reset()
    end

    on_exit(fn ->
      try do
        KeymapActive.reset()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "user-defined insert-mode overrides" do
    test "Ctrl+J bound to :next_line overrides default (continue)" do
      KeymapActive.bind(:insert, "C-j", :next_line, "Next line")

      assert {:execute, :next_line, _} = Insert.handle_key({?j, 0x02}, fresh_state())
    end

    test "Ctrl+K bound to :prev_line overrides default (continue)" do
      KeymapActive.bind(:insert, "C-k", :prev_line, "Prev line")

      assert {:execute, :prev_line, _} = Insert.handle_key({?k, 0x02}, fresh_state())
    end

    test "unbound key falls through to default handling" do
      # Ctrl+C is not bound, should be :continue
      assert {:continue, _} = Insert.handle_key({?c, 0x02}, fresh_state())
    end

    test "built-in keys still work when user overrides exist" do
      KeymapActive.bind(:insert, "C-j", :next_line, "Next line")

      # Escape should still transition to normal
      assert {:transition, :normal, _} = Insert.handle_key({27, 0}, fresh_state())

      # Backspace should still delete
      assert {:execute, :delete_before, _} = Insert.handle_key({127, 0}, fresh_state())

      # Printable chars should still insert
      assert {:execute, {:insert_char, "a"}, _} = Insert.handle_key({?a, 0}, fresh_state())
    end
  end
end
