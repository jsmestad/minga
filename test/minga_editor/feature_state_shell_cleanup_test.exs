defmodule MingaEditor.FeatureStateShellCleanupTest do
  # Mutates the global shell registry persistent_term so the fake shell can be resolved by shell id.
  use ExUnit.Case, async: false

  alias MingaEditor.FeatureState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Registry
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  @source {:extension, :fake_feature}
  @other_source {:extension, :other_feature}
  @feature :sidebar

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

    on_exit(fn ->
      Registry.reset_for_test()
      Registry.seed_builtin()
    end)

    :ok
  end

  test "editor cleanup invokes active and stashed shell feature-state cleanup callbacks" do
    active_context = context_with_feature_state(:active_owned, :active_other)
    stashed_context = context_with_feature_state(:stashed_owned, :stashed_other)

    state = %EditorState{
      port_manager: self(),
      workspace: workspace(),
      shell_id: :fake_shell,
      shell: MingaEditor.Test.FakeShell,
      shell_state: %{contexts: [active_context]},
      shell_state_stash: %{fake_shell: %{contexts: [stashed_context]}}
    }

    cleaned = EditorState.drop_feature_state_source(state, @source)

    [cleaned_context] = cleaned.shell_state.contexts
    [cleaned_stashed_context] = cleaned.shell_state_stash.fake_shell.contexts
    restored = SessionState.restore_tab_context(workspace(), cleaned_context)
    restored_stashed = SessionState.restore_tab_context(workspace(), cleaned_stashed_context)

    assert SessionState.get_feature_state(restored, @source, @feature) == nil
    assert SessionState.get_feature_state(restored, @other_source, @feature) == :active_other
    assert SessionState.get_feature_state(restored_stashed, @source, @feature) == nil

    assert SessionState.get_feature_state(restored_stashed, @other_source, @feature) ==
             :stashed_other
  end

  @spec context_with_feature_state(atom(), atom()) :: MingaEditor.State.Tab.Context.t()
  defp context_with_feature_state(owned, other) do
    workspace()
    |> SessionState.put_feature_state(@source, @feature, owned)
    |> SessionState.put_feature_state(@other_source, @feature, other)
    |> SessionState.to_tab_context()
  end

  @spec workspace() :: SessionState.t()
  defp workspace do
    %SessionState{viewport: Viewport.new(24, 80), feature_state: FeatureState.new()}
  end
end
