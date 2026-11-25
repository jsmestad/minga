defmodule Minga.Keymap.Scope.UserOverrideTest do
  @moduledoc "Tests for user-defined scope overrides via Keymap.Active."
  use ExUnit.Case, async: true

  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Scope

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

    test "user override for the picker scope works" do
      assert :not_found =
               Scope.resolve_key(:picker, :insert, {?n, 0x02},
                 keymap_server: test_keymap_server()
               )

      KeymapActive.bind(test_keymap_server(), {:picker, :insert}, "C-n", :picker_next, "Next")

      assert {:command, :picker_next} =
               Scope.resolve_key(:picker, :insert, {?n, 0x02},
                 keymap_server: test_keymap_server()
               )
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

  describe "keys_for_command/4" do
    @ctrl 0x02
    @arrow_down 57_353
    @arrow_down_mac 0xF701

    defp picker_keys(command),
      do: Scope.keys_for_command(:picker, :insert, command, keymap_server: test_keymap_server())

    test "lists the default single keys of a command" do
      assert picker_keys(:picker_next) ==
               Enum.sort([{?j, @ctrl}, {@arrow_down, 0}, {@arrow_down_mac, 0}])

      assert {?k, @ctrl} in picker_keys(:picker_prev)
      refute {?j, 0} in picker_keys(:picker_next)
    end

    test "a user binding adds its key" do
      KeymapActive.bind(test_keymap_server(), {:picker, :insert}, "C-n", :picker_next, "Next")

      assert {?n, @ctrl} in picker_keys(:picker_next)
      assert {?j, @ctrl} in picker_keys(:picker_next)
    end

    test "a user binding that takes a default key removes it from the old command" do
      KeymapActive.bind(test_keymap_server(), {:picker, :insert}, "C-j", :picker_select, "Open")

      refute {?j, @ctrl} in picker_keys(:picker_next)
      assert {@arrow_down, 0} in picker_keys(:picker_next)
      assert {?j, @ctrl} in picker_keys(:picker_select)
    end

    test "every listed key resolves to the command" do
      KeymapActive.bind(test_keymap_server(), {:picker, :insert}, "C-j", :picker_prev, "Previous")

      for command <- [:picker_next, :picker_prev], key <- picker_keys(command) do
        assert {:command, ^command} =
                 Scope.resolve_key(:picker, :insert, key, keymap_server: test_keymap_server())
      end
    end

    test "an unknown scope or an unbound command has no keys" do
      context = [keymap_server: test_keymap_server()]

      assert Scope.keys_for_command(:no_such_scope, :insert, :picker_next, context) == []
      assert picker_keys(:no_such_command) == []
      assert Scope.keys_for_command(:picker, :normal, :picker_next, context) == []
    end
  end

  describe ":keymap_server context routes to the requested server" do
    # Discriminating tests: bind on server A, resolve against server B, prove
    # the override is consulted. Without this, a regression that ignored the
    # context would still pass the producer-and-asserter-share-a-server tests.
    test "binding on server_a is not visible when resolving against server_b" do
      server_a = start_supervised!({KeymapActive, name: nil}, id: :server_a)
      server_b = start_supervised!({KeymapActive, name: nil}, id: :server_b)

      KeymapActive.bind(server_a, {:agent, :normal}, "~", :only_on_a, "Only A")

      assert {:command, :only_on_a} =
               Scope.resolve_key(:agent, :normal, {?~, 0}, keymap_server: server_a)

      # Server B has no override for `~`, so the agent default applies (which
      # is :not_found for tilde, per the scope defaults).
      assert :not_found =
               Scope.resolve_key(:agent, :normal, {?~, 0}, keymap_server: server_b)
    end

    test "different bindings on server_a and server_b are honored independently" do
      server_a = start_supervised!({KeymapActive, name: nil}, id: :server_a)
      server_b = start_supervised!({KeymapActive, name: nil}, id: :server_b)

      KeymapActive.bind(server_a, {:agent, :normal}, "y", :yank_a, "Yank A")
      KeymapActive.bind(server_b, {:agent, :normal}, "y", :yank_b, "Yank B")

      assert {:command, :yank_a} =
               Scope.resolve_key(:agent, :normal, {?y, 0}, keymap_server: server_a)

      assert {:command, :yank_b} =
               Scope.resolve_key(:agent, :normal, {?y, 0}, keymap_server: server_b)
    end
  end
end
