defmodule Minga.Mode.InsertTest do
  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Mode.Insert

  defp fresh_state, do: Mode.initial_state()

  describe "Escape key" do
    test "Escape transitions to :normal when insert mode did not change the buffer" do
      assert {:transition, :normal, _} = Insert.handle_key({27, 0}, fresh_state())
    end

    test "Escape moves cursor left after insert mode changed the buffer" do
      state = %{fresh_state() | insert_changed: true}

      assert {:execute_then_transition, [:move_left], :normal, _} =
               Insert.handle_key({27, 0}, state)
    end

    test "Escape with any modifier still moves cursor left after insert mode changed the buffer" do
      state = %{fresh_state() | insert_changed: true}

      assert {:execute_then_transition, [:move_left], :normal, _} =
               Insert.handle_key({27, 4}, state)
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
  use ExUnit.Case, async: true

  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Bindings
  alias Minga.Mode
  alias Minga.Mode.Insert

  defp fresh_state, do: Mode.initial_state()

  # Builds a mode_trie by merging filetype bindings on top of global insert bindings.
  defp test_keymap_server do
    Process.get(:minga_config_keymap, KeymapActive)
  end

  defp state_with_trie(filetype \\ :text) do
    global = KeymapActive.mode_trie(test_keymap_server(), :insert)

    ft_trie = KeymapActive.filetype_mode_trie(test_keymap_server(), filetype, :insert)

    mode_trie =
      Enum.reduce(ft_trie.children, global, fn {key, %{command: cmd, description: desc}}, acc ->
        if cmd, do: Bindings.bind(acc, [key], cmd, desc || ""), else: acc
      end)

    %{fresh_state() | filetype: filetype, mode_trie: mode_trie}
  end

  setup do
    keymap_server = start_supervised!({KeymapActive, name: nil})
    previous_keymap_server = Process.put(:minga_config_keymap, keymap_server)

    on_exit(fn ->
      if is_nil(previous_keymap_server) do
        Process.delete(:minga_config_keymap)
      else
        Process.put(:minga_config_keymap, previous_keymap_server)
      end
    end)

    :ok
  end

  describe "user-defined insert-mode overrides" do
    test "Ctrl+J bound to :next_line overrides default (continue)" do
      KeymapActive.bind(test_keymap_server(), :insert, "C-j", :next_line, "Next line")

      assert {:execute, :next_line, _} = Insert.handle_key({?j, 0x02}, state_with_trie())
    end

    test "Ctrl+K bound to :prev_line overrides default (continue)" do
      KeymapActive.bind(test_keymap_server(), :insert, "C-k", :prev_line, "Prev line")

      assert {:execute, :prev_line, _} = Insert.handle_key({?k, 0x02}, state_with_trie())
    end

    test "unbound key falls through to default handling" do
      # Ctrl+C is not bound, should be :continue
      assert {:continue, _} = Insert.handle_key({?c, 0x02}, state_with_trie())
    end

    test "built-in keys still work when user overrides exist" do
      KeymapActive.bind(test_keymap_server(), :insert, "C-j", :next_line, "Next line")
      state = state_with_trie()

      # Escape should still transition to normal
      assert {:transition, :normal, _} = Insert.handle_key({27, 0}, state)

      # Backspace should still delete
      assert {:execute, :delete_before, _} = Insert.handle_key({127, 0}, state)

      # Printable chars should still insert
      assert {:execute, {:insert_char, "a"}, _} = Insert.handle_key({?a, 0}, state)
    end
  end

  describe "filetype-scoped insert-mode overrides" do
    test "filetype binding fires when filetype matches" do
      KeymapActive.bind(test_keymap_server(), :insert, "C-j", :org_special, "Org special",
        filetype: :org
      )

      assert {:execute, :org_special, _} = Insert.handle_key({?j, 0x02}, state_with_trie(:org))
    end

    test "filetype binding does not fire for different filetype" do
      KeymapActive.bind(test_keymap_server(), :insert, "C-j", :org_special, "Org special",
        filetype: :org
      )

      assert {:continue, _} = Insert.handle_key({?j, 0x02}, state_with_trie(:elixir))
    end

    test "filetype binding shadows global binding for same key" do
      KeymapActive.bind(test_keymap_server(), :insert, "C-j", :global_next, "Global next")

      KeymapActive.bind(test_keymap_server(), :insert, "C-j", :org_special, "Org special",
        filetype: :org
      )

      assert {:execute, :org_special, _} = Insert.handle_key({?j, 0x02}, state_with_trie(:org))
      assert {:execute, :global_next, _} = Insert.handle_key({?j, 0x02}, state_with_trie(:elixir))
    end

    test "global binding fires when no filetype binding exists" do
      KeymapActive.bind(test_keymap_server(), :insert, "C-k", :global_prev, "Global prev")

      assert {:execute, :global_prev, _} = Insert.handle_key({?k, 0x02}, state_with_trie(:org))
    end
  end
end
