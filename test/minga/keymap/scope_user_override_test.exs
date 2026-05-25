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
