defmodule Minga.Keymap.ScopeRegistryTest do
  # Mutates the global keymap scope registry in persistent_term.
  use ExUnit.Case, async: false

  alias Minga.Keymap.Scope

  setup do
    on_exit(fn ->
      Scope.unregister_source({:extension, :scope_test})
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

  test "rejects duplicate scope names from different sources" do
    assert {:error, {:duplicate_scope, :editor, :builtin, {:extension, :scope_collision}}} =
             Scope.register({:extension, :scope_collision}, :editor, Minga.Keymap.Scope.Editor)
  end
end
