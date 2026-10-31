defmodule Minga.Keymap.ScopeRegistryTest do
  # Mutates the global keymap scope registry in persistent_term.
  use ExUnit.Case, async: false

  alias Minga.Keymap.Scope
  alias Minga.Config.Options
  alias Minga.Keymap.Active
  alias MingaEditor.Frontend.Protocol.GUI

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

  test "live settings preserve registered names and overrides while fixed owners stay private" do
    source = {:extension, :scope_test}
    name = :scope_test_runtime
    options = start_supervised!({Options, name: nil})
    live = start_supervised!({Active, name: nil})

    fixed =
      start_supervised!(
        Supervisor.child_spec(
          {Active, name: nil, scope_modules: Scope.builtin_modules()},
          id: make_ref()
        )
      )

    fixed_before = GUI.config_state(options, fixed)

    refute Map.has_key?(Active.scope_declarations(live), name)
    assert :ok = Scope.register(source, name, Minga.Keymap.Scope.Editor)
    assert Scope.registered_declarations()[name] == Minga.Keymap.Scope.Editor
    assert Active.scope_declarations(live)[name] == Minga.Keymap.Scope.Editor
    refute Map.has_key?(Active.scope_declarations(fixed), name)
    assert :ok = Active.bind(live, {name, :normal}, "Q", :move_down, "Named scope override")

    assert Enum.any?(GUI.config_state(options, live).keybindings, fn entry ->
             entry.mode == "scope_test_runtime/normal" and entry.key == "Q" and
               entry.command == "move_down" and entry.description == "Named scope override"
           end)

    assert GUI.config_state(options, fixed) == fixed_before

    assert :ok = Scope.unregister_source(source)
    refute Map.has_key?(Active.scope_declarations(live), name)

    refute Enum.any?(
             GUI.config_state(options, live).keybindings,
             &String.starts_with?(&1.mode, "scope_test_runtime/")
           )
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
