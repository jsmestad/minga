defmodule MingaEditor.FeatureStateShellCleanupTest do
  # Mutates the global shell registry persistent_term so the fake shell can be resolved by shell id.
  use ExUnit.Case, async: false

  alias MingaEditor.FeatureState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Identity
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.StateStash
  alias MingaEditor.State, as: EditorState

  @source {:extension, :fake_feature}
  @other_source {:extension, :other_feature}
  @feature :sidebar
  @builtin_source :builtin
  @config_source :config

  setup do
    Registry.reset_for_test()
    Registry.seed_builtin()

    :ok =
      Registry.register({:extension, :fake_shell}, %{
        id: :fake_shell,
        module: MingaEditor.Test.FakeShell,
        display_name: "Fake Shell",
        description: "Test shell",
        default?: false,
        capabilities: []
      })

    :ok =
      Registry.register({:extension, :fake_shell_alt}, %{
        id: :fake_shell_alt,
        module: MingaEditor.Test.FakeShellAlt,
        display_name: "Fake Shell Alt",
        description: "Alternate test shell",
        default?: false,
        capabilities: []
      })

    on_exit(fn ->
      Registry.reset_for_test()
      Registry.seed_builtin()
    end)

    :ok
  end

  test "editor cleanup invokes active and stashed shell feature-state cleanup callbacks" do
    active_context = context_with_feature_state(:active_owned, :active_other)
    stashed_context = context_with_feature_state(:stashed_owned, :stashed_other)

    entry = Registry.get(:fake_shell)
    stashed_entry = Registry.get(:fake_shell_alt)

    runtime =
      Runtime.new(stashed_entry, %{contexts: [stashed_context]})
      |> Runtime.activate(entry, %{contexts: [active_context]})

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: workspace(),
      shell_runtime: runtime
    }

    cleaned = MingaEditor.FeatureStateWorkflow.drop_source(state, @source)

    [cleaned_context] = Runtime.state(cleaned.shell_runtime).contexts

    assert %StateStash{
             identity: %Identity{module: MingaEditor.Test.FakeShellAlt},
             state: stashed_shell_state
           } = Map.fetch!(Runtime.stash(cleaned.shell_runtime), Identity.new(stashed_entry))

    [cleaned_stashed_context] = stashed_shell_state.contexts
    restored = SessionState.restore_tab_context(workspace(), cleaned_context)
    restored_stashed = SessionState.restore_tab_context(workspace(), cleaned_stashed_context)

    assert SessionState.get_feature_state(restored, @source, @feature) == nil
    assert SessionState.get_feature_state(restored, @other_source, @feature) == :active_other
    assert SessionState.get_feature_state(restored_stashed, @source, @feature) == nil

    assert SessionState.get_feature_state(restored_stashed, @other_source, @feature) ==
             :stashed_other
  end

  test "drop_extension_sources removes active and stashed extension values but preserves config and builtin" do
    active_context = context_with_all_sources(:active_extension)
    stashed_context = context_with_all_sources(:stashed_extension)
    entry = Registry.get(:fake_shell)
    stashed_entry = Registry.get(:fake_shell_alt)

    runtime =
      Runtime.new(stashed_entry, %{contexts: [stashed_context]})
      |> Runtime.activate(entry, %{contexts: [active_context]})

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: workspace(),
      shell_runtime: runtime
    }

    cleaned = MingaEditor.FeatureStateWorkflow.drop_extension_sources(state)
    [cleaned_active] = Runtime.state(cleaned.shell_runtime).contexts

    %StateStash{state: %{contexts: [cleaned_stashed]}} =
      Map.fetch!(Runtime.stash(cleaned.shell_runtime), Identity.new(stashed_entry))

    Enum.each([cleaned_active, cleaned_stashed], fn context ->
      restored = SessionState.restore_tab_context(workspace(), context)
      assert SessionState.get_feature_state(restored, @source, @feature) == nil
      assert SessionState.get_feature_state(restored, @builtin_source, @feature) == :builtin_value
      assert SessionState.get_feature_state(restored, @config_source, @feature) == :config_value
    end)
  end

  test "editor cleanup does not transform a stash from an obsolete registration" do
    stashed_context = context_with_feature_state(:stashed_owned, :stashed_other)
    stale_entry = Registry.get(:fake_shell)

    runtime =
      Runtime.new(stale_entry, %{contexts: [stashed_context]})
      |> Runtime.activate(Runtime.default_entry(), %MingaEditor.Shell.Traditional.State{})

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: workspace(),
      shell_runtime: runtime
    }

    assert :ok = Registry.unregister_source({:extension, :fake_shell})

    assert :ok =
             Registry.register({:extension, :fake_shell}, %{
               id: :fake_shell,
               module: MingaEditor.Test.FakeShell,
               display_name: "Fake Shell",
               description: "Replacement shell",
               default?: false,
               capabilities: []
             })

    cleaned = MingaEditor.FeatureStateWorkflow.drop_source(state, @source)

    %StateStash{state: %{contexts: [unchanged_context]}} =
      Map.fetch!(Runtime.stash(cleaned.shell_runtime), Identity.new(stale_entry))

    restored = SessionState.restore_tab_context(workspace(), unchanged_context)

    assert SessionState.get_feature_state(restored, @source, @feature) == :stashed_owned
  end

  @spec context_with_feature_state(atom(), atom()) :: MingaEditor.State.Tab.Context.t()
  defp context_with_feature_state(owned, other) do
    workspace()
    |> SessionState.put_feature_state(@source, @feature, owned)
    |> SessionState.put_feature_state(@other_source, @feature, other)
    |> SessionState.to_tab_context()
  end

  @spec context_with_all_sources(atom()) :: MingaEditor.State.Tab.Context.t()
  defp context_with_all_sources(extension_value) do
    workspace()
    |> SessionState.put_feature_state(@source, @feature, extension_value)
    |> SessionState.put_feature_state(@builtin_source, @feature, :builtin_value)
    |> SessionState.put_feature_state(@config_source, @feature, :config_value)
    |> SessionState.to_tab_context()
  end

  @spec workspace() :: SessionState.t()
  defp workspace do
    %SessionState{feature_state: FeatureState.new()}
  end
end
