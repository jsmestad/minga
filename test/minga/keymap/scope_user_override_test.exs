defmodule Minga.Keymap.Scope.UserOverrideTest do
  @moduledoc "Tests for user-defined scope overrides via Keymap.Active."
  use ExUnit.Case, async: true

  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Scope

  setup do
    keymap_server =
      String.to_atom("scope_override_#{System.unique_integer([:positive])}_keymap")

    start_supervised!({KeymapActive, name: keymap_server})
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

  @spec test_keymap_server() :: GenServer.server()
  defp test_keymap_server, do: Process.get(:minga_config_keymap, KeymapActive)

  describe "scope overrides take priority over scope defaults" do
    test "user override for agent scope normal mode wins" do
      # y is :agent_copy_code_block by default
      assert {:command, :agent_copy_code_block} =
               Scope.resolve_key(:agent, :normal, {?y, 0}, keymap_server: test_keymap_server())

      # Override it
      KeymapActive.bind(
        test_keymap_server(),
        {:agent, :normal},
        "y",
        :my_custom_yank,
        "Custom yank"
      )

      # Now the override takes priority
      assert {:command, :my_custom_yank} =
               Scope.resolve_key(:agent, :normal, {?y, 0}, keymap_server: test_keymap_server())
    end

    test "user override for file_tree scope works" do
      # q is :tree_close by default
      assert {:command, :tree_close} =
               Scope.resolve_key(:file_tree, :normal, {?q, 0},
                 keymap_server: test_keymap_server()
               )

      KeymapActive.bind(
        test_keymap_server(),
        {:file_tree, :normal},
        "q",
        :custom_close,
        "Custom close"
      )

      assert {:command, :custom_close} =
               Scope.resolve_key(:file_tree, :normal, {?q, 0},
                 keymap_server: test_keymap_server()
               )
    end

    test "non-overridden keys still work from scope defaults" do
      KeymapActive.bind(test_keymap_server(), {:agent, :normal}, "y", :my_yank, "My yank")

      # q should still be agent_close from the default scope keymap
      assert {:command, :agent_close} =
               Scope.resolve_key(:agent, :normal, {?q, 0}, keymap_server: test_keymap_server())
    end

    test "user can add new keys to a scope" do
      # tilde is not bound in agent scope by default
      assert :not_found =
               Scope.resolve_key(:agent, :normal, {?~, 0}, keymap_server: test_keymap_server())

      KeymapActive.bind(
        test_keymap_server(),
        {:agent, :normal},
        "~",
        :toggle_debug,
        "Toggle debug"
      )

      assert {:command, :toggle_debug} =
               Scope.resolve_key(:agent, :normal, {?~, 0}, keymap_server: test_keymap_server())
    end
  end
end
