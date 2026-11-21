defmodule MingaEditor.Commands.EditTimelineTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.FileChange
  alias MingaEditor.Agent.FileEventWorkflow
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Commands.EditTimeline, as: EditTimelineCommands
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.AgentReview
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    a = Path.join(dir, "a.ex")
    b = Path.join(dir, "b.ex")
    File.write!(a, "a2")
    File.write!(b, "b1")
    buffer = start_supervised!({BufferProcess, content: "keep my editor"})
    window = Window.new_agent_chat(1, 24, 80)
    task_supervisor = start_supervised!({Task.Supervisor, []})
    scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
    :ok = EffectScheduler.attach(scheduler, self())

    {tab_bar, workspace} =
      Tab.new_agent(1, "Agent")
      |> TabBar.new(dir)
      |> TabBar.add_workspace("Agent")

    tab_bar = TabBar.move_tab_to_workspace(tab_bar, 1, workspace.id)

    timeline =
      EditTimeline.new()
      |> EditTimeline.record_edit(%FileChange{
        path: a,
        before_content: "a0",
        after_content: "a1",
        tool_call_id: "tc1",
        tool_name: "edit"
      })
      |> EditTimeline.record_edit(%FileChange{
        path: b,
        before_content: "b0",
        after_content: "b1",
        tool_call_id: "tc2",
        tool_name: "edit"
      })
      |> EditTimeline.record_edit(%FileChange{
        path: a,
        before_content: "a1",
        after_content: "a2",
        tool_call_id: "tc3",
        tool_name: "edit"
      })

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: nil},
      effect_scheduler: scheduler,
      workspace: %SessionState{
        keymap_scope: :agent,
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      shell_runtime:
        Runtime.new(Runtime.default_entry(), ShellState.install_tab_bar(%ShellState{}, tab_bar))
    }

    state =
      Workflow.install_agent_ui(
        state,
        UIState.replace_edit_timeline(state.workspace.agent_ui, timeline)
      )

    %{state: state, a: a, b: b, buffer: buffer}
  end

  test "file navigation reviews cumulative changes in first-seen order without opening buffers",
       context do
    %{state: state, a: a, b: b, buffer: buffer} = context
    original_window = Windows.active_struct(state.workspace.windows)

    pending = EditTimelineCommands.execute(state, :timeline_next_file)
    assert pending.workspace.agent_ui.view == state.workspace.agent_ui.view
    assert Windows.active_struct(pending.workspace.windows) == original_window

    {reviewing_a, outcome} = apply_candidate(pending)
    assert {:completed, _review} = outcome.value

    assert %DiffReview{path: ^a, after_lines: ["a2"]} =
             review =
             Preview.diff_review(reviewing_a.workspace.agent_ui.view.preview)

    assert DiffReview.original_lines(review) == ["a0"]

    assert Windows.active_struct(reviewing_a.workspace.windows).content ==
             {:agent_review, :semantic}

    assert reviewing_a.workspace.agent_ui.view.presentation.focus == :file_viewer

    {reviewing_b, _outcome} =
      reviewing_a |> EditTimelineCommands.execute(:timeline_next_file) |> apply_candidate()

    assert Preview.selected_path(reviewing_b.workspace.agent_ui.view.preview) == b

    {reviewing_a, _outcome} =
      reviewing_b |> EditTimelineCommands.execute(:timeline_prev_file) |> apply_candidate()

    assert Preview.selected_path(reviewing_a.workspace.agent_ui.view.preview) == a
    assert Buffer.content(buffer) == "keep my editor"
  end

  test "a delayed review cannot take focus after the user chooses another surface", %{
    state: state,
    a: a
  } do
    pending = EditTimelineCommands.review_file(state, a)
    outcome = receive_candidate(pending)
    ui = UIState.set_focus(pending.workspace.agent_ui, :chat) |> UIState.set_input_focused(true)
    moved = Workflow.install_agent_ui(pending, ui)

    assert {^moved, %Outcome{value: {:stale, :review_context_changed}} = stale} =
             AgentReview.apply(moved, outcome)

    EffectScheduler.finalize(moved.effect_scheduler, stale)
  end

  test "a delayed review cannot replace a newer explicit selection", %{state: state, a: a, b: b} do
    pending = EditTimelineCommands.review_file(state, a)
    outcome = receive_candidate(pending)

    other =
      DiffReview.from_hunks(
        b,
        "b1",
        EditTimeline.cumulative_hunks(state.workspace.agent_ui.view.edit_timeline, b)
      )

    preview = Preview.set_diff(pending.workspace.agent_ui.view.preview, other)

    moved =
      Workflow.install_agent_ui(
        pending,
        UIState.replace_preview(pending.workspace.agent_ui, preview)
      )

    assert {^moved, %Outcome{value: {:stale, :review_context_changed}} = stale} =
             AgentReview.apply(moved, outcome)

    EffectScheduler.finalize(moved.effect_scheduler, stale)
  end

  test "a write while a review is loading retires the acquired revision", %{state: state, a: a} do
    pending = EditTimelineCommands.review_file(state, a)
    outcome = receive_candidate(pending)

    changed =
      FileEventWorkflow.changed(pending, %FileChange{
        path: a,
        before_content: "a2",
        after_content: "a3",
        tool_call_id: "tc4",
        tool_name: "edit"
      })

    assert {^changed, %Outcome{value: {:stale, :review_context_changed}} = stale} =
             AgentReview.apply(changed, outcome)

    EffectScheduler.finalize(changed.effect_scheduler, stale)
  end

  test "a newer post-image without its file event cannot be paired with older cumulative hunks",
       %{
         state: state,
         a: a
       } do
    File.write!(a, "new prefix\na2")
    pending = EditTimelineCommands.review_file(state, a)
    {failed, outcome} = apply_candidate(pending)

    assert outcome.value == {:failed, :review_source_changed}
    assert failed.workspace.agent_ui == state.workspace.agent_ui
    assert failed.workspace.windows == state.workspace.windows
    assert NoticeWorkflow.message(failed) =~ "Review again"
  end

  test "deletion cannot pair its live offer with a recreated empty file", %{state: state, a: path} do
    File.write!(path, "")

    state =
      FileEventWorkflow.changed(state, %FileChange{
        path: path,
        before_content: "a2",
        after_content: :absent,
        tool_call_id: "delete",
        tool_name: "delete_file"
      })

    {updated, outcome} = state |> EditTimelineCommands.review_file(path) |> apply_candidate()

    assert outcome.value == {:failed, :snapshot_unavailable}
    assert updated.workspace.agent_ui.view.preview == state.workspace.agent_ui.view.preview
    assert File.read!(path) == ""
  end

  test "review acquisition follows human-reprojected post-images rather than historical snapshots",
       %{
         state: state,
         a: a
       } do
    for {baseline, content} <- [
          {"human\na0", "human\na2"},
          {"human\na0", "human\na2\n"},
          {"人e\u0301\na0", "人e\u0301\na2\n"}
        ] do
      File.write!(a, content)

      timeline =
        EditTimeline.reproject(
          state.workspace.agent_ui.view.edit_timeline,
          a,
          String.split(baseline, "\n"),
          String.split(content, "\n")
        )

      current =
        Workflow.install_agent_ui(
          state,
          UIState.replace_edit_timeline(state.workspace.agent_ui, timeline)
        )

      {reviewing, outcome} = current |> EditTimelineCommands.review_file(a) |> apply_candidate()
      assert {:completed, %DiffReview{} = review} = outcome.value
      assert DiffReview.original_lines(review) == String.split(baseline, "\n")
      assert review.after_lines == String.split(content, "\n")
      assert Preview.diff_review(reviewing.workspace.agent_ui.view.preview) == review
    end
  end

  test "human reprojection retires a loaded result even when its cumulative hunk positions are unchanged",
       %{
         state: state,
         a: a
       } do
    pending = EditTimelineCommands.review_file(state, a)
    outcome = receive_candidate(pending)
    File.write!(a, "a3")

    timeline =
      EditTimeline.reproject(pending.workspace.agent_ui.view.edit_timeline, a, ["a0"], ["a3"])

    changed =
      Workflow.install_agent_ui(
        pending,
        UIState.replace_edit_timeline(pending.workspace.agent_ui, timeline)
      )

    assert {^changed, %Outcome{value: {:stale, :review_context_changed}} = stale} =
             AgentReview.apply(changed, outcome)

    EffectScheduler.finalize(changed.effect_scheduler, stale)
  end

  test "failed acquisition reports the failure without replacing selection or focus", %{
    state: state,
    a: a
  } do
    File.rm!(a)
    pending = EditTimelineCommands.review_file(state, a)
    {failed, outcome} = apply_candidate(pending)

    assert outcome.value == {:failed, :enoent}
    assert failed.workspace.agent_ui == state.workspace.agent_ui
    assert failed.workspace.windows == state.workspace.windows
    assert NoticeWorkflow.message(failed) =~ "Could not review"
    assert NoticeWorkflow.message(failed) =~ ":enoent"
  end

  test "historical edit navigation remains harmless without an active buffer", %{state: state} do
    assert EditTimelineCommands.execute(state, :timeline_next_edit) == state
  end

  test "explicit Review focuses an existing Agent pane without replacing the active human window",
       %{
         state: state,
         a: a,
         buffer: buffer
       } do
    human = Window.new(2, buffer, 24, 80)
    {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)

    windows = %Windows{
      tree: tree,
      map: %{1 => state.workspace.windows.map[1], 2 => human},
      active: 2,
      next_id: 3
    }

    workspace =
      state.workspace
      |> SessionState.set_windows(windows)
      |> SessionState.set_buffers(%Buffers{active: buffer, list: [buffer]})
      |> SessionState.set_keymap_scope(:editor)

    state = %{state | workspace: workspace}
    {reviewing, outcome} = state |> EditTimelineCommands.review_file(a) |> apply_candidate()
    assert {:completed, %DiffReview{}} = outcome.value
    assert reviewing.workspace.windows.active == 1
    assert reviewing.workspace.windows.map[1].content == {:agent_review, :semantic}
    assert reviewing.workspace.windows.map[2].content == human.content
    assert reviewing.workspace.windows.map[2].viewport == human.viewport
    assert reviewing.workspace.keymap_scope == :agent
    assert Buffer.content(buffer) == "keep my editor"
  end

  test "an absent Agent pane fails visibly instead of converting a human window", %{
    state: state,
    a: a,
    buffer: buffer
  } do
    human = Window.new(1, buffer, 24, 80)
    state = %{state | workspace: SessionState.replace_window(state.workspace, 1, human)}
    {failed, outcome} = state |> EditTimelineCommands.review_file(a) |> apply_candidate()
    assert outcome.value == {:failed, :review_pane_unavailable}
    assert failed.workspace == state.workspace
    assert NoticeWorkflow.message(failed) =~ "Reopen the Agent workspace"
  end

  test "a replacement window cannot receive a result admitted by its predecessor", %{
    state: state,
    a: a
  } do
    pending = EditTimelineCommands.review_file(state, a)
    outcome = receive_candidate(pending)
    replacement = Window.new_agent_chat(1, 24, 80)

    changed = %{
      pending
      | workspace: SessionState.replace_window(pending.workspace, 1, replacement)
    }

    assert {^changed, %Outcome{value: {:stale, :review_context_changed}} = stale} =
             AgentReview.apply(changed, outcome)

    EffectScheduler.finalize(changed.effect_scheduler, stale)
  end

  defp receive_candidate(state) do
    scheduler = state.effect_scheduler
    assert_receive {:effect_result, ^scheduler, %Outcome{} = outcome}, 1_000
    assert :ok = EffectScheduler.claim(scheduler, outcome)
    outcome
  end

  defp apply_candidate(state) do
    outcome = receive_candidate(state)
    {updated, outcome} = AgentReview.apply(state, outcome)
    :ok = EffectScheduler.finalize(state.effect_scheduler, outcome)
    {updated, outcome}
  end
end
