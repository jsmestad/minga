defmodule MingaEditor.Shell.Traditional.ModalWorkflowTest do
  use ExUnit.Case, async: true

  alias Minga.Mode.CommandState
  alias MingaEditor.KeyDispatch
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: WorkspaceState
  alias MingaEditor.Shell.Traditional.ModalWorkflow

  test "command input changes invalidate generations, including input ABA with empty candidates" do
    first = refresh_input(TestHelpers.base_state(), "zzzz-no-command")
    second = refresh_input(first, "zzzz-no-command-x")
    repeated = refresh_input(second, "zzzz-no-command")

    assert ModalWorkflow.command_completion(first).candidates == []
    assert ModalWorkflow.command_completion(second).candidates == []

    generations =
      Enum.map([first, second, repeated], &ModalWorkflow.command_completion(&1).generation)

    assert Enum.all?(generations, &(&1 > 0))
    assert Enum.uniq(generations) == generations
  end

  test "cursor and selection refreshes retain the owning generation" do
    state = refresh_input(TestHelpers.base_state(), "")
    generation = ModalWorkflow.command_completion(state).generation

    mode_state =
      CommandState.new("")
      |> CommandState.move_candidate(1)
      |> CommandState.move_cursor(:left)

    refreshed =
      %{state | workspace: WorkspaceState.transition_mode(state.workspace, :command, mode_state)}
      |> KeyDispatch.refresh_command_completion()

    assert ModalWorkflow.command_completion(refreshed).selected == 1
    assert ModalWorkflow.command_completion(refreshed).generation == generation
  end

  test "closing or dismissing then reopening the same command gets a fresh generation" do
    original = refresh_input(TestHelpers.base_state(), "write")
    generation = ModalWorkflow.command_completion(original).generation

    for close <- [&ModalWorkflow.close/1, &ModalWorkflow.dismiss/1] do
      closed = close.(original)
      assert ModalWorkflow.command_completion(closed) == nil
      reopened = refresh_input(closed, "write")
      assert ModalWorkflow.command_completion(reopened).generation != generation
    end
  end

  test "candidate changes invalidate an unchanged input presentation" do
    state = refresh_input(TestHelpers.base_state(), "w")
    previous = ModalWorkflow.command_completion(state)
    [_removed | retained] = previous.candidates

    replacement =
      ModalWorkflow.new_command_completion_payload(state,
        filter_text: previous.filter_text,
        candidates: retained,
        total: length(retained)
      )

    assert replacement.generation != previous.generation
  end

  defp refresh_input(state, input) do
    workspace =
      WorkspaceState.transition_mode(state.workspace, :command, CommandState.new(input))

    %{state | workspace: workspace}
    |> KeyDispatch.refresh_command_completion()
  end
end
