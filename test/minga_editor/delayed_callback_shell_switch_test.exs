defmodule MingaEditor.DelayedCallbackShellSwitchTest do
  # Serial because these tests exercise shell switching through the global shell registry.
  use ExUnit.Case, async: false

  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalShellState
  alias MingaEditor.Test.FakeShell
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.TodoSearchSource

  setup do
    Registry.reset_for_test()
    Registry.seed_builtin()

    :ok =
      Registry.register({:extension, :delayed_callback_fake_shell}, %{
        id: :fake,
        module: FakeShell,
        display_name: "Fake",
        description: "Fake shell",
        capabilities: [:tui]
      })

    on_exit(fn ->
      Registry.reset_for_test()
      Registry.seed_builtin()
    end)

    :ok
  end

  test "commit generation success clears ownership without touching or replaying a foreign shell" do
    assert_commit_generation_result_is_dropped(
      {:git_commit_message_generated, {:ok, "Generated subject"}}
    )
  end

  test "commit generation error clears ownership without touching or replaying a foreign shell" do
    assert_commit_generation_result_is_dropped(
      {:git_commit_message_generated, {:error, "generation failed"}}
    )
  end

  test "commit generation timeout clears ownership without touching or replaying a foreign shell" do
    assert_commit_generation_result_is_dropped(:git_generate_timeout)
  end

  test "picker candidate delivery is dropped without touching or replaying a foreign shell" do
    traditional_state =
      TestHelpers.base_state()
      |> Map.put(:rendering, :disabled)
      |> PickerUI.open(TodoSearchSource)

    assert_receive {:picker_fetch_candidates, TodoSearchSource, revision, _ctx}
    assert is_reference(revision)

    state = ShellWorkflow.switch(traditional_state, :fake)
    foreign_shell_state = Runtime.state(state.shell_runtime)
    message_store = state.message_store
    items = [%Item{id: %{path: "/tmp/stale.ex", line: 1}, label: "stale candidate"}]
    result = {:ok, items, Candidate.from_items(items), %{status: "stale status"}}

    assert {:noreply, new_state} =
             MingaEditor.handle_info(
               {:picker_candidates_result, TodoSearchSource, revision, result},
               state
             )

    assert new_state == state
    assert Runtime.state(new_state.shell_runtime) == foreign_shell_state
    assert new_state.message_store == message_store

    restored = ShellWorkflow.switch(new_state, :traditional)
    assert %TraditionalShellState{} = Runtime.state(restored.shell_runtime)
    assert Runtime.state(restored.shell_runtime).modal == :none
    assert Runtime.state(restored.shell_runtime).notice.message == nil
    assert restored.message_store == message_store
  end

  defp assert_commit_generation_result_is_dropped(message) do
    generation_ref = make_ref()

    state =
      TestHelpers.base_state()
      |> Map.put(:rendering, :disabled)
      |> Map.put(:git_commit_gen_ref, generation_ref)
      |> ShellWorkflow.switch(:fake)

    foreign_shell_state = Runtime.state(state.shell_runtime)
    message_store = state.message_store

    assert {:noreply, new_state} = MingaEditor.handle_info(message, state)
    assert new_state.git_commit_gen_ref == nil
    assert Runtime.state(new_state.shell_runtime) == foreign_shell_state
    assert new_state.message_store == message_store
    assert new_state == %{state | git_commit_gen_ref: nil}

    restored = ShellWorkflow.switch(new_state, :traditional)
    assert %TraditionalShellState{} = Runtime.state(restored.shell_runtime)
    assert Runtime.state(restored.shell_runtime).modal == :none
    assert Runtime.state(restored.shell_runtime).notice.message == nil
    assert restored.message_store == message_store
  end
end
