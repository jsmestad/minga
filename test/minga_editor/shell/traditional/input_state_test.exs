defmodule MingaEditor.Shell.Traditional.InputStateTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ClickRegions
  alias MingaEditor.Shell.Traditional.InputState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState

  import MingaEditor.RenderPipeline.TestHelpers

  test "one render installs both click-region sets and reset clears both" do
    input =
      InputState.install_click_regions(
        %InputState{},
        [{2, 6, :show_messages}],
        [{0, 3, :previous_tab}, {1, 4, 8, {:tab_goto_id, 7}}]
      )

    assert InputState.modeline_command_at(input, 2) == :show_messages
    assert InputState.modeline_command_at(input, 6) == nil
    assert InputState.tab_bar_command_at(input, 0, 3) == :previous_tab
    assert InputState.tab_bar_command_at(input, 1, 5) == {:tab_goto_id, 7}

    assert InputState.click_regions(InputState.reset_click_regions(input)) == %ClickRegions{}
  end

  test "a stale leader generation cannot expire its replacement" do
    {first_generation, input} = InputState.begin_space_leader(%InputState{})
    input = InputState.install_space_leader_timer(input, first_generation, make_ref())
    input = InputState.reset_space_leader(input)
    {replacement_generation, input} = InputState.begin_space_leader(input)

    assert {:stale, unchanged} = InputState.expire_space_leader(input, first_generation)
    assert unchanged == input
    assert InputState.space_leader_pending?(unchanged)

    assert {:expired, expired} =
             InputState.expire_space_leader(unchanged, replacement_generation)

    refute InputState.space_leader_pending?(expired)
    assert InputState.space_leader_timer(expired) == nil
  end

  test "Editor timeout delivery ignores an old generation and expires the current one" do
    shell_state = %TraditionalState{}
    {old_generation, shell_state} = TraditionalState.begin_space_leader(shell_state)
    shell_state = TraditionalState.reset_space_leader(shell_state)
    {current_generation, shell_state} = TraditionalState.begin_space_leader(shell_state)

    state = install_shell_state(base_state(), shell_state)

    assert {:noreply, stale_state} =
             MingaEditor.handle_info({:space_leader_timeout, old_generation}, state)

    assert TraditionalState.space_leader_pending?(Runtime.state(stale_state.shell_runtime))

    assert {:noreply, expired_state} =
             MingaEditor.handle_info({:space_leader_timeout, current_generation}, stale_state)

    refute TraditionalState.space_leader_pending?(Runtime.state(expired_state.shell_runtime))
  end

  defp install_shell_state(state, shell_state) do
    runtime = Runtime.install_traditional_state(state.shell_runtime, shell_state)

    then(state, fn state -> %{state | shell_runtime: runtime} end)
  end
end
