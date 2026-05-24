defmodule MingaDired.KeymapScopeTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Scope
  alias MingaDired.KeymapScope

  @enter 13
  @escape 27

  setup do
    Scope.register({:extension, :dired}, KeymapScope)
    on_exit(fn -> Scope.unregister(:dired) end)
    :ok
  end

  describe "normal mode bindings" do
    test "Enter resolves to dired_open_entry" do
      assert {:command, :dired_open_entry} = Scope.resolve_key(:dired, :normal, {@enter, 0})
    end

    test "- resolves to dired_parent" do
      assert {:command, :dired_parent} = Scope.resolve_key(:dired, :normal, {?-, 0})
    end

    test "q resolves to dired_close" do
      assert {:command, :dired_close} = Scope.resolve_key(:dired, :normal, {?q, 0})
    end

    test "Escape resolves to dired_close" do
      assert {:command, :dired_close} = Scope.resolve_key(:dired, :normal, {@escape, 0})
    end

    test "g. resolves to dired_toggle_hidden" do
      {:prefix, node} = Scope.resolve_key(:dired, :normal, {?g, 0})
      assert {:command, :dired_toggle_hidden} = Scope.resolve_key_in_node(node, {?., 0})
    end

    test "gs resolves to dired_cycle_sort via prefix" do
      {:prefix, node} = Scope.resolve_key(:dired, :normal, {?g, 0})
      assert {:command, :dired_cycle_sort} = Scope.resolve_key_in_node(node, {?s, 0})
    end

    test "gd resolves to dired_toggle_details via prefix" do
      {:prefix, node} = Scope.resolve_key(:dired, :normal, {?g, 0})
      assert {:command, :dired_toggle_details} = Scope.resolve_key_in_node(node, {?d, 0})
    end

    test "gx resolves to dired_open_external via prefix" do
      {:prefix, node} = Scope.resolve_key(:dired, :normal, {?g, 0})
      assert {:command, :dired_open_external} = Scope.resolve_key_in_node(node, {?x, 0})
    end

    test "gr resolves to dired_refresh via prefix" do
      {:prefix, node} = Scope.resolve_key(:dired, :normal, {?g, 0})
      assert {:command, :dired_refresh} = Scope.resolve_key_in_node(node, {?r, 0})
    end
  end

  describe "vim editing keys fall through" do
    test "i is not bound (falls through to insert mode)" do
      assert :not_found = Scope.resolve_key(:dired, :normal, {?i, 0})
    end

    test "d is not bound (falls through to delete operator)" do
      assert :not_found = Scope.resolve_key(:dired, :normal, {?d, 0})
    end

    test "o is not bound (falls through to open line below)" do
      assert :not_found = Scope.resolve_key(:dired, :normal, {?o, 0})
    end

    test "A is not bound (falls through to append end of line)" do
      assert :not_found = Scope.resolve_key(:dired, :normal, {?A, 0})
    end

    test "j is not bound (falls through to move down)" do
      assert :not_found = Scope.resolve_key(:dired, :normal, {?j, 0})
    end

    test "k is not bound (falls through to move up)" do
      assert :not_found = Scope.resolve_key(:dired, :normal, {?k, 0})
    end
  end

  describe "CUA mode bindings" do
    test "Enter resolves to dired_open_entry" do
      assert {:command, :dired_open_entry} = Scope.resolve_key(:dired, :cua, {@enter, 0})
    end

    test "Escape resolves to dired_close" do
      assert {:command, :dired_close} = Scope.resolve_key(:dired, :cua, {@escape, 0})
    end
  end

  describe "scope registration" do
    test "dired is in all_scopes" do
      assert :dired in Scope.all_scopes()
    end

    test "module_for returns Dired module" do
      assert Scope.module_for(:dired) == MingaDired.KeymapScope
    end
  end
end
