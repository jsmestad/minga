defmodule MingaEditor.DelayedCallbackShellSwitchTest do
  # Serial because these tests exercise shell switching through the global shell registry.
  use ExUnit.Case, async: false

  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ClickRegions
  alias MingaEditor.Shell.Traditional.Observatory
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalShellState
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.State, as: EditorState
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

  test "Observatory tick after a shell switch cannot touch the foreign shell" do
    token = make_ref()
    timer = Process.send_after(self(), {:observatory_tick, token}, 60_000)

    state =
      TestHelpers.base_state()
      |> Map.put(:rendering, :disabled)
      |> SidebarWorkflow.open_observatory({timer, token})
      |> ShellWorkflow.switch(:fake)

    foreign_shell_state = Runtime.state(state.shell_runtime)

    assert Process.read_timer(timer) == false
    assert {:noreply, new_state} = MingaEditor.handle_info({:observatory_tick, token}, state)
    assert new_state == state
    assert Runtime.state(new_state.shell_runtime) == foreign_shell_state

    restored = ShellWorkflow.switch(new_state, :traditional)
    observatory = restored.shell_runtime |> Runtime.state() |> TraditionalShellState.observatory()
    refute Observatory.visible?(observatory)
    assert Observatory.timer(observatory) == nil
  end

  test "space-leader timeout after a shell switch cannot touch the foreign shell" do
    state = TestHelpers.base_state() |> Map.put(:rendering, :disabled)

    {generation, shell_state} =
      state.shell_runtime
      |> Runtime.state()
      |> TraditionalShellState.begin_space_leader()

    timer = Process.send_after(self(), {:space_leader_timeout, generation}, 60_000)

    shell_state =
      shell_state
      |> TraditionalShellState.install_space_leader_timer(generation, timer)
      |> TraditionalShellState.install_click_regions([{0, 2, :modeline}], [{0, 2, :next_tab}])

    runtime =
      Runtime.update_traditional_state(state.shell_runtime, fn _current -> shell_state end)

    state =
      state
      |> EditorState.apply_shell_runtime_transition(runtime)
      |> ShellWorkflow.switch(:fake)

    foreign_shell_state = Runtime.state(state.shell_runtime)

    assert {:noreply, new_state} =
             MingaEditor.handle_info({:space_leader_timeout, generation}, state)

    assert Process.read_timer(timer) == false
    assert new_state == state
    assert Runtime.state(new_state.shell_runtime) == foreign_shell_state

    restored = ShellWorkflow.switch(new_state, :traditional)
    restored_shell_state = Runtime.state(restored.shell_runtime)
    refute TraditionalShellState.space_leader_pending?(restored_shell_state)
    assert TraditionalShellState.space_leader_timer(restored_shell_state) == nil
    assert TraditionalShellState.click_regions(restored_shell_state) == %ClickRegions{}
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
