defmodule MingaGitPorcelain.CommandsBranchDeleteTest do
  @moduledoc "Tests branch delete confirmation command handling."

  # Uses the global Minga.Project singleton to verify picker reopen behavior.
  use ExUnit.Case, async: false

  alias Minga.Git
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Mode.BranchDeleteConfirmState
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.KeyDispatch
  alias MingaEditor.Session.State, as: SessionState
  alias MingaGitPorcelain.Commands, as: GitCommands
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker

  setup %{tmp_dir: dir} do
    reset_global_project!()
    GitStub.set_root(dir, dir)

    GitStub.set_branches(dir, [
      %Git.BranchInfo{name: "main", current: true},
      %Git.BranchInfo{name: "feature", current: false}
    ])

    Minga.Project.switch(dir)
    await_project_rebuild(dir)

    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: task_supervisor, observer: self()},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())

    on_exit(fn ->
      GitStub.clear(dir)
      reset_global_project!()
    end)

    %{git_root: dir, scheduler: scheduler}
  end

  @tag :tmp_dir
  test "confirmed branch deletion applies after the mode transition and reopens the picker", %{
    git_root: git_root,
    scheduler: scheduler
  } do
    pending =
      git_root
      |> state_in_delete_mode(scheduler)
      |> KeyDispatch.handle_key(?y, 0)

    assert pending.workspace.editing.mode == :normal
    assert %Minga.Mode.State{} = pending.workspace.editing.mode_state

    result = receive_effect(pending, scheduler)
    assert result.shell_runtime.state.notice.message == "Deleted branch feature"

    assert {:picker,
            %{picker_ui: %{source: MingaGitPorcelain.UI.Picker.GitBranchSource, picker: picker}}} =
             MingaEditor.Shell.Runtime.state(result.shell_runtime).modal

    assert %Picker{items: items} = picker
    refute Enum.any?(items, fn item -> item.label == "feature" end)
  end

  @tag :tmp_dir
  test "cancel applies after the mode transition and reopens the picker", %{
    git_root: git_root,
    scheduler: scheduler
  } do
    pending =
      git_root
      |> state_in_delete_mode(scheduler)
      |> KeyDispatch.handle_key(?n, 0)

    assert pending.workspace.editing.mode == :normal
    assert %Minga.Mode.State{} = pending.workspace.editing.mode_state

    result = receive_effect(pending, scheduler)
    assert result.shell_runtime.state.notice.message == "Branch delete cancelled"

    assert {:picker,
            %{picker_ui: %{source: MingaGitPorcelain.UI.Picker.GitBranchSource, picker: picker}}} =
             MingaEditor.Shell.Runtime.state(result.shell_runtime).modal

    assert %Picker{items: items} = picker
    assert Enum.any?(items, fn item -> item.label == "feature" end)
  end

  @tag :tmp_dir
  test "unmerged safe-delete failure enters force confirmation", %{git_root: git_root} do
    GitStub.set_branch_delete_result(git_root, "feature", false, {:error, "not fully merged"})
    state = build_state()

    result = GitCommands.execute(state, {:branch_delete_confirm, git_root, "feature", false})

    assert result.shell_runtime.state.notice.message == "Delete failed: not fully merged"
    assert result.workspace.editing.mode == :branch_delete_confirm

    assert %BranchDeleteConfirmState{name: "feature", phase: :force, reason: "not fully merged"} =
             result.workspace.editing.mode_state
  end

  @tag :tmp_dir
  test "force delete failure reports force-specific error", %{git_root: git_root} do
    GitStub.set_branch_delete_result(git_root, "feature", true, {:error, "branch not found"})
    state = build_state()

    result = GitCommands.execute(state, {:branch_delete_confirm, git_root, "feature", true})

    assert result.shell_runtime.state.notice.message == "Force delete failed: branch not found"
  end

  @tag :tmp_dir
  test "source unload exits branch delete confirmation" do
    mode_state = BranchDeleteConfirmState.new("/repo", "feature")
    state = build_state()
    workspace = SessionState.transition_mode(state.workspace, :branch_delete_confirm, mode_state)

    assert {:handled, result} =
             MingaGitPorcelain.Commands.handle_editor_event(
               %{state | workspace: workspace},
               {:source_unload, {:extension, :minga_git_porcelain}}
             )

    assert result.workspace.editing.mode == :normal
    assert %Minga.Mode.State{} = result.workspace.editing.mode_state
  end

  defp state_in_delete_mode(git_root, scheduler) do
    mode_state = BranchDeleteConfirmState.new(git_root, "feature")
    state = build_state(scheduler)
    workspace = SessionState.transition_mode(state.workspace, :branch_delete_confirm, mode_state)
    %{state | workspace: workspace}
  end

  defp build_state(scheduler \\ nil) do
    %EditorState{
      effect_scheduler: scheduler,
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %SessionState{}
    }
  end

  defp receive_effect(state, scheduler) do
    assert_receive {:effect_lifecycle, %Outcome{status: :running} = running}, 2_000
    {:noreply, state} = MingaEditor.handle_info({:effect_lifecycle, running}, state)

    assert_receive {:effect_result, ^scheduler, %Outcome{} = outcome}, 2_000
    {:noreply, state} = MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)
    state
  end

  defp reset_global_project! do
    root = File.cwd!()
    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(root)
    await_project_rebuild(root)
  end

  defp await_project_rebuild(root) do
    if Minga.Project.rebuilding?() do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^root}},
                     5_000
    end

    _ = :sys.get_state(Minga.Project)
  end
end
