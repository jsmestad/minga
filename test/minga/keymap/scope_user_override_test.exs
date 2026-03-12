defmodule Minga.Keymap.Scope.UserOverrideTest do
  @moduledoc "Tests for user-defined scope overrides via Keymap.Active."
  use ExUnit.Case, async: false

  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Scope

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

  describe "scope overrides take priority over scope defaults" do
    test "user override for agent scope normal mode wins" do
      # y is :agent_copy_code_block by default
      assert {:command, :agent_copy_code_block} = Scope.resolve_key(:agent, :normal, {?y, 0})

      # Override it
      KeymapActive.bind({:agent, :normal}, "y", :my_custom_yank, "Custom yank")

      # Now the override takes priority
      assert {:command, :my_custom_yank} = Scope.resolve_key(:agent, :normal, {?y, 0})
    end

    test "user override for file_tree scope works" do
      # q is :tree_close by default
      assert {:command, :tree_close} = Scope.resolve_key(:file_tree, :normal, {?q, 0})

      KeymapActive.bind({:file_tree, :normal}, "q", :custom_close, "Custom close")
      assert {:command, :custom_close} = Scope.resolve_key(:file_tree, :normal, {?q, 0})
    end

    test "non-overridden keys still work from scope defaults" do
      KeymapActive.bind({:agent, :normal}, "y", :my_yank, "My yank")

      # q should still be agent_close from the default scope keymap
      assert {:command, :agent_close} = Scope.resolve_key(:agent, :normal, {?q, 0})
    end

    test "user can add new keys to a scope" do
      # tilde is not bound in agent scope by default
      assert :not_found = Scope.resolve_key(:agent, :normal, {?~, 0})

      KeymapActive.bind({:agent, :normal}, "~", :toggle_debug, "Toggle debug")
      assert {:command, :toggle_debug} = Scope.resolve_key(:agent, :normal, {?~, 0})
    end
  end
end
