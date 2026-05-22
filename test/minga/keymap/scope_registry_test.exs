defmodule Minga.Keymap.ScopeRegistryTest do
  # Mutates the global keymap scope registry in persistent_term.
  use ExUnit.Case, async: false

  alias Minga.Keymap.Scope

  setup do
    on_exit(fn ->
      Scope.unregister_source({:extension, :scope_test})
      Scope.unregister_source({:extension, :scope_other})
      Scope.unregister_source({:extension, :scope_collision})
    end)

    :ok
  end

  test "registers and unregisters source-owned scopes" do
    source = {:extension, :scope_test}
    name = :scope_test_runtime

    assert :ok = Scope.register(source, name, Minga.Keymap.Scope.Editor)
    assert Scope.module_for(name) == Minga.Keymap.Scope.Editor
    assert name in Scope.all_scopes()

    assert :ok = Scope.unregister_source(source)
    assert Scope.module_for(name) == nil
    assert Scope.module_for(:editor) == Minga.Keymap.Scope.Editor
  end

  test "unregister_source preserves other extension-owned scopes" do
    source = {:extension, :scope_test}
    other_source = {:extension, :scope_other}

    assert :ok = Scope.register(source, :scope_test_runtime, Minga.Keymap.Scope.Editor)
    assert :ok = Scope.register(other_source, :scope_other_runtime, Minga.Keymap.Scope.Agent)

    assert Scope.module_for(:scope_test_runtime) == Minga.Keymap.Scope.Editor
    assert Scope.module_for(:scope_other_runtime) == Minga.Keymap.Scope.Agent

    assert :ok = Scope.unregister_source(source)

    assert Scope.module_for(:scope_test_runtime) == nil
    assert Scope.module_for(:scope_other_runtime) == Minga.Keymap.Scope.Agent
    assert :scope_other_runtime in Scope.all_scopes()
    assert Scope.module_for(:editor) == Minga.Keymap.Scope.Editor
  end

  test "rejects duplicate scope names from different sources" do
    assert {:error, {:duplicate_scope, :editor, :builtin, {:extension, :scope_collision}}} =
             Scope.register({:extension, :scope_collision}, :editor, Minga.Keymap.Scope.Editor)
  end
end
