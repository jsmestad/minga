defmodule Minga.Mode.Visual.UserOverrideTest do
  @moduledoc "Tests for user-defined visual mode bindings via Keymap.Active."
  use ExUnit.Case, async: true

  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Mode.Visual
  alias Minga.Mode.VisualState

  defp visual_state(anchor \\ {0, 0}, type \\ :char) do
    %VisualState{visual_anchor: anchor, visual_type: type}
  end

  defp test_keymap_server do
    Process.get(:minga_config_keymap, KeymapActive)
  end

  defp visual_state_with_trie(anchor \\ {0, 0}, type \\ :char) do
    global = KeymapActive.mode_trie(test_keymap_server(), :visual)

    %VisualState{visual_anchor: anchor, visual_type: type, mode_trie: global}
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

  describe "user-defined visual-mode overrides" do
    test "Ctrl+X bound to :custom_cut executes the command" do
      KeymapActive.bind(test_keymap_server(), :visual, "C-x", :custom_cut, "Custom cut")

      state = visual_state_with_trie()
      assert {:execute, :custom_cut, _} = Visual.handle_key({?x, 0x02}, state)
    end

    test "unbound key falls through to default (continue)" do
      state = visual_state()
      # Ctrl+Z is not bound by default
      assert {:continue, _} = Visual.handle_key({?z, 0x02}, state)
    end

    test "built-in visual keys still work when user overrides exist" do
      KeymapActive.bind(test_keymap_server(), :visual, "C-x", :custom_cut, "Custom cut")

      state = visual_state()
      # Escape should still transition to normal
      assert {:transition, :normal, _} = Visual.handle_key({27, 0}, state)

      # d should still delete selection
      assert {:execute_then_transition, [:delete_visual_selection], :normal, _} =
               Visual.handle_key({?d, 0}, state)
    end
  end
end
