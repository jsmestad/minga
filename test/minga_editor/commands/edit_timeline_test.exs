defmodule MingaEditor.Commands.EditTimelineTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Commands.EditTimeline, as: EditTimelineCommands
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Session.State, as: WorkspaceState
  alias MingaEditor.Viewport

  describe "execute/2" do
    test "timeline_next_edit stays guarded when no buffer is active" do
      state = state_with_timeline()

      assert EditTimelineCommands.execute(state, :timeline_next_edit) == state
    end

    test "timeline_next_file works without an active buffer and reports open failures" do
      state = state_with_timeline()

      updated = EditTimelineCommands.execute(state, :timeline_next_file)

      assert status = MingaEditor.Shell.Traditional.NoticeWorkflow.message(updated)
      assert String.contains?(status, "Could not open agent change file /tmp/a-missing.ex")
    end

    test "timeline_prev_file wraps to the last path without an active buffer" do
      state = state_with_timeline()

      updated = EditTimelineCommands.execute(state, :timeline_prev_file)

      assert status = MingaEditor.Shell.Traditional.NoticeWorkflow.message(updated)
      assert String.contains?(status, "Could not open agent change file /tmp/b-missing.ex")
    end
  end

  defp state_with_timeline do
    timeline =
      EditTimeline.new()
      |> EditTimeline.record_edit("/tmp/a-missing.ex", "tc1", "write_file", "old", "new")
      |> EditTimeline.record_edit("/tmp/b-missing.ex", "tc2", "write_file", "old", "new")

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %WorkspaceState{viewport: Viewport.new(24, 80)}
    }
    |> then(fn state ->
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
        state,
        (&UIState.replace_edit_timeline(&1, timeline)).(state.workspace.agent_ui)
      )
    end)
  end
end
