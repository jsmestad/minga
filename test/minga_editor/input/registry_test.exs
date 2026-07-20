defmodule MingaEditor.Input.RegistryTest do
  # Mutates the global input handler registry in persistent_term.
  use ExUnit.Case, async: false

  alias MingaEditor.Input

  setup do
    Input.reset_handlers()

    on_exit(fn ->
      Input.reset_handlers()
    end)

    :ok
  end

  test "surface handlers are served from the source-owned registry in stable order without dired" do
    handlers = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})

    refute MingaEditor.Input.Dired in handlers

    assert Enum.find_index(handlers, &(&1 == MingaEditor.Input.EmptyState)) <
             Enum.find_index(handlers, &(&1 == MingaEditor.Input.Popup))

    assert Enum.find_index(handlers, &(&1 == MingaEditor.Input.Popup)) <
             Enum.find_index(handlers, &(&1 == MingaEditor.Input.Scoped))

    assert Enum.at(handlers, -1) == MingaEditor.Input.ModeFSM
  end

  test "dispatch entries preserve exact built-in, config, and extension sources" do
    extension_source = {:extension, :input_registry_test}

    :ok =
      Input.register_handler(:config, MingaEditor.Input.ExtensionOne,
        phase: :surface,
        priority: -30
      )

    :ok =
      Input.register_handler(extension_source, MingaEditor.Input.ExtensionTwo,
        phase: :surface,
        priority: -20
      )

    entries = Input.surface_handler_entries(%{editing_model: Minga.Editing.Model.Vim})

    assert {MingaEditor.Input.ExtensionOne, :config} in entries
    assert {MingaEditor.Input.ExtensionTwo, extension_source} in entries
    assert {MingaEditor.Input.MentionCompletion, :builtin} in entries
    assert [{MingaEditor.Input.ModeFSM, :builtin} | _rest] = Enum.reverse(entries)
  end

  test "extension handler priority controls relative order without callbacks on the hot path" do
    source = {:extension, :input_registry_test}

    :ok =
      Input.register_handler(source, MingaEditor.Input.GlobalBindings,
        phase: :surface,
        priority: -10
      )

    :ok =
      Input.register_handler(source, MingaEditor.Input.AgentMouse, phase: :surface, priority: -20)

    handlers = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})

    assert Enum.find_index(handlers, &(&1 == MingaEditor.Input.AgentMouse)) <
             Enum.find_index(handlers, &(&1 == MingaEditor.Input.GlobalBindings))

    # The negative-priority extension copies sort before every seeded
    # built-in. MentionCompletion (priority 10) is the lowest-priority
    # built-in with no extension duplicate, so it anchors that boundary.
    assert Enum.find_index(handlers, &(&1 == MingaEditor.Input.GlobalBindings)) <
             Enum.find_index(handlers, &(&1 == MingaEditor.Input.MentionCompletion))
  end

  test "unregister_source(:builtin) preserves seeded built-in handlers" do
    before = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})
    assert :ok = Input.unregister_source(:builtin)
    after_handlers = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})

    assert after_handlers == before
  end

  test "unregister_source removes extension-owned handlers without removing built-ins" do
    source = {:extension, :input_registry_test}

    :ok =
      Input.register_handler(source, MingaEditor.Input.GlobalBindings,
        phase: :surface,
        priority: -10
      )

    handlers_with_extension = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})
    assert Enum.count(handlers_with_extension, &(&1 == MingaEditor.Input.GlobalBindings)) == 2

    :ok = Input.unregister_source(source)
    handlers_after_cleanup = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})
    assert Enum.count(handlers_after_cleanup, &(&1 == MingaEditor.Input.GlobalBindings)) == 1
  end

  test "unregister_source preserves another extension source's handler and ordering" do
    source = {:extension, :input_registry_test}
    other_source = {:extension, :input_registry_other}

    :ok =
      Input.register_handler(source, MingaEditor.Input.ExtensionOne,
        phase: :surface,
        priority: -30
      )

    :ok =
      Input.register_handler(other_source, MingaEditor.Input.ExtensionTwo,
        phase: :surface,
        priority: -20
      )

    handlers_with_extension = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})

    assert Enum.find_index(handlers_with_extension, &(&1 == MingaEditor.Input.ExtensionOne)) <
             Enum.find_index(handlers_with_extension, &(&1 == MingaEditor.Input.ExtensionTwo))

    assert Enum.find_index(handlers_with_extension, &(&1 == MingaEditor.Input.ExtensionTwo)) <
             Enum.find_index(
               handlers_with_extension,
               &(&1 == MingaEditor.Input.MentionCompletion)
             )

    :ok = Input.unregister_source(source)
    handlers_after_cleanup = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})

    assert Enum.find(handlers_after_cleanup, &(&1 == MingaEditor.Input.ExtensionOne)) == nil

    assert Enum.find(handlers_after_cleanup, &(&1 == MingaEditor.Input.ExtensionTwo)) ==
             MingaEditor.Input.ExtensionTwo

    assert Enum.find_index(handlers_after_cleanup, &(&1 == MingaEditor.Input.ExtensionTwo)) <
             Enum.find_index(handlers_after_cleanup, &(&1 == MingaEditor.Input.MentionCompletion))
  end
end
